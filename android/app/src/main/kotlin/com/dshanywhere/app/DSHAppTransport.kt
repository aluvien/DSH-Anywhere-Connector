package com.dshanywhere.app

import android.content.Context
import com.dshanywhere.core.network.DSHAPIClient
import com.dshanywhere.core.network.DSHAPIError
import com.dshanywhere.core.network.DSHRemoteProfile
import com.dshanywhere.core.network.DSHRelayDevice
import com.dshanywhere.core.network.DSHWebSocketConnection
import com.dshanywhere.core.network.DSHWebSocketConfiguration
import com.dshanywhere.core.network.DSHWebSocketError
import com.dshanywhere.core.protocol.DSHCommand
import com.dshanywhere.core.protocol.DSHEnvelope
import com.dshanywhere.core.protocol.DSHEvent
import com.dshanywhere.core.protocol.DSHJson
import com.dshanywhere.core.protocol.epochMillisNow
import com.dshanywhere.core.protocol.DSHPairingCredential
import com.dshanywhere.core.security.DSHTokenStore
import com.dshanywhere.core.security.DSHKeystoreTokenStore
import com.dshanywhere.core.store.DSHProfileStore
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.net.URL
import java.util.UUID
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.receiveAsFlow

/**
 * The small boundary between the native UI and the machine connection.
 * Production code uses the WebSocket-backed implementation, while previews and
 * tests can inject the in-memory one. Mirrors `DSHAppTransport`.
 */
interface DSHAppTransport {
    suspend fun pair(
        serverAddress: String,
        machineId: String,
        credential: DSHPairingCredential,
        deviceName: String,
    ): DSHRemoteProfile

    suspend fun connect(): Flow<DSHEvent>

    suspend fun send(command: DSHCommand)

    suspend fun disconnect()

    suspend fun forgetPairing()

    /** Chooses which paired Mac subsequent connections target. */
    suspend fun setActiveMachine(machineId: String)

    /** Forgets one paired Mac, leaving the others intact. */
    suspend fun removeMachine(machineId: String)

    /** Devices paired to the active machine, straight from the relay. */
    suspend fun pairedDevices(): List<DSHRelayDevice>

    /** Revokes one device. The relay refuses to let a device revoke itself. */
    suspend fun revokeDevice(deviceId: String)
}

class DSHRemoteTransport(
    private val context: Context,
    private val tokenStore: DSHTokenStore = DSHKeystoreTokenStore(context),
    private val profileStore: DSHProfileStore = DSHProfileStore(context),
) : DSHAppTransport {

    private var connection: DSHWebSocketConnection? = null

    val isConfigured: Boolean get() = profileStore.profiles.isNotEmpty()

    override suspend fun pair(
        serverAddress: String,
        machineId: String,
        credential: DSHPairingCredential,
        deviceName: String,
    ): DSHRemoteProfile {
        val baseURL = DSHAPIClient.relayBaseURL(serverAddress)
        val (profile, token) = DSHAPIClient(baseURL).pair(machineId, credential, deviceName)
        tokenStore.save(token, account = profile.deviceId)
        // Adds to the machine list rather than replacing it, so pairing a
        // second Mac no longer makes the first one unreachable.
        profileStore.upsert(profile)
        return profile
    }

    override suspend fun connect(): Flow<DSHEvent> {
        val credentials = runCatching { loadCredentials() }.getOrNull()
            ?: return flow { throw DSHAPIError.MissingCredentials() }
        val (profile, token) = credentials
        connection?.let { return it.connect() }
        val relayURL = websocketURL(profile.url)
            ?: return flow { throw DSHAPIError.InvalidServerURL() }
        val socket = DSHWebSocketConnection(
            configuration = DSHWebSocketConfiguration(
                url = relayURL,
                bearerToken = token,
                deviceId = profile.deviceId,
                machineId = profile.machineId,
            ),
        )
        connection = socket
        return socket.connect()
    }

    override suspend fun send(command: DSHCommand) {
        val connection = connection ?: throw DSHWebSocketError.NotConnected()
        connection.send(command)
    }

    override suspend fun disconnect() {
        connection?.disconnect()
        connection = null
    }

    override suspend fun forgetPairing() {
        disconnect()
        val profile = profileStore.activeProfile ?: return
        tokenStore.delete(account = profile.deviceId)
        profileStore.remove(profile.machineId)
    }

    override suspend fun setActiveMachine(machineId: String) {
        // The socket carries the old machine's identity, so it cannot be reused.
        disconnect()
        profileStore.setActive(machineId)
    }

    override suspend fun removeMachine(machineId: String) {
        if (profileStore.activeMachineId == machineId) disconnect()
        profileStore.profiles.firstOrNull { it.machineId == machineId }?.let { profile ->
            tokenStore.delete(account = profile.deviceId)
        }
        profileStore.remove(machineId)
    }

    override suspend fun pairedDevices(): List<DSHRelayDevice> {
        val (profile, token) = loadCredentials()
        return DSHAPIClient(profile.url).devices(machineId = profile.machineId, token = token)
    }

    override suspend fun revokeDevice(deviceId: String) {
        val (profile, token) = loadCredentials()
        DSHAPIClient(profile.url).revokeDevice(
            machineId = profile.machineId, deviceId = deviceId, token = token,
        )
    }

    private fun loadCredentials(): Pair<DSHRemoteProfile, String> {
        val profile = profileStore.activeProfile
        val token = profile?.let { tokenStore.read(account = it.deviceId) }
        if (profile == null || token == null) throw DSHAPIError.MissingCredentials()
        return profile to token
    }

    private fun websocketURL(base: URL): String? {
        val scheme = when (base.protocol.lowercase()) {
            "https" -> "wss"
            "http" -> "ws"
            else -> return null
        }
        val path = base.path.trimEnd('/') + "/v1/connect"
        val portPart = if (base.port != -1) ":${base.port}" else ""
        return "$scheme://${base.host}$portPart$path"
    }
}

/**
 * A deterministic transport used by previews and by the first-run app shell
 * before a machine has been paired. Mirrors `DSHPreviewTransport`.
 */
class DSHPreviewTransport : DSHAppTransport {
    private var continuation: Channel<DSHEvent>? = null
    private var nextSequence: Long = 1
    private val deviceID = "preview-device"
    private val machineID = "preview-machine"

    override suspend fun pair(
        serverAddress: String,
        machineId: String,
        credential: DSHPairingCredential,
        deviceName: String,
    ) = DSHRemoteProfile(
        relayBaseURL = "https://preview.invalid",
        deviceId = deviceID,
        machineId = machineID,
        machineName = "Preview Mac",
    )

    override suspend fun connect(): Flow<DSHEvent> {
        val channel = Channel<DSHEvent>(Channel.UNLIMITED)
        continuation = channel
        emit("connection.ready", null, buildJsonObject { })
        return channel.receiveAsFlow()
    }

    override suspend fun send(command: DSHCommand) {
        when (command.type) {
            "session.create" -> {
                val id = UUID.randomUUID().toString()
                val title = command.payload.stringField("title") ?: "New session"
                emit("session.created", id, buildJsonObject {
                    put("id", JsonPrimitive(id))
                    put("title", JsonPrimitive(title))
                    put("updatedAt", JsonPrimitive(epochMillisNow()))
                })
            }
            "prompt.send" -> {
                val sessionID = command.sessionId ?: return
                val text = command.payload.stringField("text") ?: return
                val userID = UUID.randomUUID().toString()
                emit("user.message.accepted", sessionID, DSHJson.parseToJsonElement(
                    """{"id":"$userID","role":"user","markdown":${jsonString(text)}}""",
                ))
                val toolID = UUID.randomUUID().toString()
                emit("tool.started", sessionID, DSHJson.parseToJsonElement(
                    """{"id":"$toolID","name":"deepseek_harness","status":"running","detail":"Working on your request"}""",
                ))
                val messageID = UUID.randomUUID().toString()
                emit("assistant.message.delta", sessionID, DSHJson.parseToJsonElement(
                    """{"messageId":"$messageID","text":"I received your request. "}""",
                ))
                emit("assistant.message.completed", sessionID, DSHJson.parseToJsonElement(
                    """{"id":"$messageID","role":"assistant","markdown":"I received your request. The preview transport is ready for a real Harness connection."}""",
                ))
                emit("tool.completed", sessionID, DSHJson.parseToJsonElement(
                    """{"id":"$toolID","name":"deepseek_harness","status":"completed","detail":"Finished"}""",
                ))
                emit("turn.state.changed", sessionID, DSHJson.parseToJsonElement(
                    """{"sessionId":"$sessionID","state":"idle"}""",
                ))
            }
            "approval.decide" -> {
                val approvalID = command.payload.stringField("approvalId") ?: return
                val allowed = command.payload.boolField("allow") ?: false
                emit("approval.resolved", command.sessionId, DSHJson.parseToJsonElement(
                    """{"id":${jsonString(approvalID)},"allowed":$allowed}""",
                ))
            }
        }
    }

    override suspend fun disconnect() {
        continuation?.close()
        continuation = null
    }

    override suspend fun forgetPairing() {
        disconnect()
    }

    override suspend fun setActiveMachine(machineId: String) {}

    override suspend fun removeMachine(machineId: String) {}

    override suspend fun pairedDevices(): List<DSHRelayDevice> = emptyList()

    override suspend fun revokeDevice(deviceId: String) {}

    private fun emit(type: String, sessionID: String?, payload: JsonElement) {
        val channel = continuation ?: return
        val envelope = DSHEnvelope(
            version = 1,
            messageId = UUID.randomUUID().toString(),
            deviceId = deviceID,
            machineId = machineID,
            sessionId = sessionID,
            sequence = nextSequence,
            timestamp = epochMillisNow(),
            type = type,
            payload = payload,
        )
        nextSequence += 1
        channel.trySend(DSHEvent(envelope))
    }

    private fun jsonString(value: String): String =
        DSHJson.encodeToString(String.serializer(), value)
}

private fun JsonElement.stringField(key: String): String? =
    (this as? JsonObject)?.get(key)?.let { it as? JsonPrimitive }?.content

private fun JsonElement.boolField(key: String): Boolean? =
    (this as? JsonObject)?.get(key)?.let { it as? JsonPrimitive }?.content?.toBooleanStrictOrNull()

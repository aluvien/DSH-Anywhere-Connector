package com.dshanywhere.core.network

import com.dshanywhere.core.protocol.DSHCommand
import com.dshanywhere.core.protocol.DSHEnvelope
import com.dshanywhere.core.protocol.DSHEvent
import com.dshanywhere.core.protocol.DSHJson
import com.dshanywhere.core.protocol.DSHRelayMessage
import com.dshanywhere.core.protocol.DSHRelayPayloadMessage
import com.dshanywhere.core.protocol.DSHRelayRole
import com.dshanywhere.core.protocol.startsNewSequenceEpoch
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.CancellationException
import okio.ByteString
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.atomic.AtomicBoolean

sealed class DSHWebSocketError(message: String) : Exception(message) {
    class NotConnected : DSHWebSocketError("The Relay WebSocket is not connected.")
    class InvalidMessage :
        DSHWebSocketError("The Relay WebSocket message is not valid protocol JSON.")
    class UnsupportedProtocolVersion(version: Int) :
        DSHWebSocketError("Unsupported protocol version $version.")
    class UnauthorizedRelayRole :
        DSHWebSocketError("The Relay authenticated this connection with an unexpected role.")
    class Relay(code: String, msg: String) : DSHWebSocketError("Relay error $code: $msg")
    class Closed : DSHWebSocketError("The Relay WebSocket connection is closed.")
}

data class DSHWebSocketConfiguration(
    /** `wss://relay.example/v1/connect`, rather than a direct Harness socket. */
    val url: String,
    val bearerToken: String,
    val deviceId: String,
    val machineId: String,
    val backoff: DSHExponentialBackoff = DSHExponentialBackoff(),
    /**
     * null means retry until explicitly disconnected. A finite value is useful
     * for deterministic tests.
     */
    val maximumReconnectAttempts: Int? = null,
)

/**
 * Owns the relay socket. Only machine-originated payloads for the paired
 * machine become `DSHEvent`s; relay control traffic never reaches the store.
 * Mirrors the `DSHWebSocketConnection` actor in
 * ios/DSHAnywhere/Core/Networking/DSHWebSocketConnection.swift.
 */
class DSHWebSocketConnection(
    private val configuration: DSHWebSocketConfiguration,
    initialLastSequence: Long = 0,
    private val client: OkHttpClient = OkHttpClient(),
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    private var eventChannel = Channel<DSHEvent>(Channel.UNLIMITED)

    private val stateFlow = MutableStateFlow<DSHConnectionState>(DSHConnectionState.Disconnected)
    val state: Flow<DSHConnectionState> get() = stateFlow

    @Volatile var lastSequence: Long = initialLastSequence
        private set
    @Volatile var stopped: Boolean = false
        private set

    @Volatile private var socket: WebSocket? = null
    @Volatile private var runner: Job? = null
    private val connectingLock = Any()

    /**
     * Starts one receive stream. Calling connect again returns the existing
     * stream while a connection is active.
     */
    fun connect(): Flow<DSHEvent> {
        synchronized(connectingLock) {
            if (!stopped) {
                runner?.let { if (it.isActive) return eventChannel.receiveAsFlow() }
            }
            stopped = false
            // A disconnected stream is finished for good; a fresh connect must
            // hand out a fresh channel, mirroring AsyncThrowingStream's
            // recreation in the Swift actor.
            if (eventChannel.isClosedForSend) {
                eventChannel = Channel(Channel.UNLIMITED)
            }
            runner = scope.launch { run() }
            return eventChannel.receiveAsFlow()
        }
    }

    fun disconnect() {
        synchronized(connectingLock) {
            stopped = true
            runner?.cancel()
            runner = null
            socket?.close(CLOSE_GOING_AWAY, null)
            socket = null
            stateFlow.value = DSHConnectionState.Disconnected
            publishTransportState()
            eventChannel.close()
        }
    }

    /**
     * The UI may construct placeholder identifiers. The paired identity is
     * always substituted here before the command leaves the phone.
     */
    suspend fun send(command: DSHCommand) {
        // The receive loop deliberately keeps the stream alive while the socket
        // reconnects. A user can tap Send during that short window, so wait for
        // the next relay.ready handshake instead of failing immediately with
        // the misleading "not connected" alert.
        val deadline = System.currentTimeMillis() + 10_000
        while ((stateFlow.value != DSHConnectionState.Connected || socket == null) && !stopped) {
            if (System.currentTimeMillis() >= deadline) throw DSHWebSocketError.NotConnected()
            delay(100)
        }
        val active = socket ?: throw DSHWebSocketError.NotConnected()
        if (stopped) throw DSHWebSocketError.NotConnected()
        sendRelay(normalized(command), task = active)
    }

    private suspend fun run() {
        var attempt = 0
        while (!stopped && coroutineActive()) {
            stateFlow.value = if (attempt == 0) DSHConnectionState.Connecting
            else DSHConnectionState.Reconnecting(attempt)
            publishTransportState()
            val frames = Channel<String>(Channel.UNLIMITED)
            try {
                val request = Request.Builder()
                    .url(configuration.url)
                    .header("Authorization", "Bearer ${configuration.bearerToken}")
                    .header("User-Agent", "dsh-anywhere/1")
                    .build()
                val webSocket = client.newWebSocket(request, object : WebSocketListener() {
                    override fun onMessage(webSocket: WebSocket, text: String) {
                        frames.trySend(text)
                    }

                    override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                        frames.trySend(bytes.utf8())
                    }

                    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                        frames.close(t)
                    }

                    override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                        frames.close()
                    }
                })
                socket = webSocket
                var didReceiveReady = false
                for (text in frames) {
                    if (stopped || !coroutineActive()) break
                    if (consume(text, webSocket)) {
                        didReceiveReady = true
                        attempt = 0
                    }
                }
                if (didReceiveReady) attempt = maxOf(attempt, 1)
                // Reaching here without an exception means the socket closed
                // cleanly; fall through into the retry path below.
                if (stopped || !coroutineActive()) break
                throw DSHWebSocketError.Closed()
            } catch (e: CancellationException) {
                break
            } catch (e: Exception) {
                socket = null
                if (stopped || !coroutineActive()) break
                attempt += 1
                val maximum = configuration.maximumReconnectAttempts
                if (maximum != null && attempt > maximum) {
                    stateFlow.value = DSHConnectionState.Failed(e.message ?: e.javaClass.simpleName)
                    publishTransportState()
                    eventChannel.close(e)
                    return
                }
                stateFlow.value = DSHConnectionState.Reconnecting(attempt)
                publishTransportState()
                delay(configuration.backoff.delayMillisFor(attempt))
            } finally {
                frames.close()
            }
        }
        if (!stopped) {
            stateFlow.value = DSHConnectionState.Failed(DSHWebSocketError.Closed().message ?: "closed")
            publishTransportState()
        }
    }

    private suspend fun coroutineActive(): Boolean = currentCoroutineContext().isActive

    /**
     * Returns true for the relay handshake, which is the point at which a
     * resume command can be safely routed to a connected Mac.
     */
    private suspend fun consume(text: String, task: WebSocket): Boolean {
        val relay = DSHRelayMessage.parse(text) ?: throw DSHWebSocketError.InvalidMessage()
        return when (relay) {
            is DSHRelayMessage.Ready -> {
                val ready = relay.message
                if (ready.machineId != configuration.machineId || ready.role != DSHRelayRole.device) {
                    throw DSHWebSocketError.UnauthorizedRelayRole()
                }
                stateFlow.value = DSHConnectionState.Connected
                publishTransportState()
                sendRelay(
                    DSHCommand.resume(
                        deviceId = configuration.deviceId,
                        machineId = configuration.machineId,
                        lastSequence = lastSequence,
                    ),
                    task = task,
                )
                // A relay handshake is the only readiness signal guaranteed on
                // every connection. Request the authoritative session list here,
                // rather than relying on view lifecycle or a replayed local
                // connection.ready event that may no longer be buffered.
                sendRelay(
                    DSHCommand.listSessions(
                        deviceId = configuration.deviceId,
                        machineId = configuration.machineId,
                    ),
                    task = task,
                )
                true
            }
            is DSHRelayMessage.Presence -> {
                val presence = relay.message
                if (presence.machineId == configuration.machineId && presence.role == DSHRelayRole.machine) {
                    yieldControl("machine.presence", kotlinx.serialization.json.JsonPrimitive(presence.online))
                }
                false
            }
            is DSHRelayMessage.Error ->
                throw DSHWebSocketError.Relay(relay.message.code, relay.message.message)
            is DSHRelayMessage.Payload -> {
                val payload = relay.message
                // The relay may notify this device about control messages. Only
                // events from its paired machine belong to this client stream.
                if (payload.sender != DSHRelayRole.machine ||
                    payload.machineId != configuration.machineId
                ) {
                    return false
                }
                val event = DSHEvent.fromPayload(payload.body) ?: return false
                if (event.envelope.version != 1) {
                    throw DSHWebSocketError.UnsupportedProtocolVersion(event.envelope.version)
                }
                if (event.startsNewSequenceEpoch(comparedTo = lastSequence)) {
                    // A Connector restart resets its in-memory replay
                    // sequence. A full session snapshot is also authoritative.
                    lastSequence = 0
                }
                if (event.sequence > lastSequence) lastSequence = event.sequence
                eventChannel.trySend(event)
                false
            }
        }
    }

    /**
     * Pushes an out-of-band control event onto the same stream the store reads.
     * The envelope carries sequence 0 and the reducer handles these before its
     * replay-window gate, exactly like the Swift `yieldControl`.
     */
    private fun yieldControl(type: String, payload: kotlinx.serialization.json.JsonElement) {
        if (eventChannel.isClosedForSend) return
        val envelope = DSHEnvelope(
            version = 1,
            messageId = java.util.UUID.randomUUID().toString(),
            deviceId = configuration.deviceId,
            machineId = configuration.machineId,
            sessionId = null,
            sequence = 0,
            timestamp = com.dshanywhere.core.protocol.epochMillisNow(),
            type = type,
            payload = payload,
        )
        eventChannel.trySend(DSHEvent(envelope))
    }

    private fun publishTransportState() {
        yieldControl("transport.state", stateFlow.value.toWireJson())
    }

    private fun normalized(command: DSHCommand): DSHCommand =
        command.copy(deviceId = configuration.deviceId, machineId = configuration.machineId)

    private suspend fun sendRelay(command: DSHCommand, task: WebSocket) {
        val payload = DSHRelayPayloadMessage.wrappingCommand(
            machineId = configuration.machineId,
            sender = DSHRelayRole.device,
            command = command,
        )
        val sent = task.send(payload.encodeText())
        if (!sent) throw DSHWebSocketError.NotConnected()
    }

    private companion object {
        const val CLOSE_GOING_AWAY = 1001
    }
}

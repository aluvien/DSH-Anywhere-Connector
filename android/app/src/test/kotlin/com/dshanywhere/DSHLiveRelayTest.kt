package com.dshanywhere

import com.dshanywhere.core.network.DSHAPIClient
import com.dshanywhere.core.network.DSHWebSocketConfiguration
import com.dshanywhere.core.network.DSHWebSocketConnection
import com.dshanywhere.core.protocol.DSHChatMessage
import com.dshanywhere.core.protocol.DSHCommand
import com.dshanywhere.core.protocol.DSHJson
import com.dshanywhere.core.protocol.DSHMessageRole
import com.dshanywhere.core.protocol.DSHPairingCredential
import com.dshanywhere.core.store.DSHEventReducer
import com.dshanywhere.core.store.DSHStoreState
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull

/**
 * End-to-end check of the client's networking core against a real local relay
 * plus the mock machine fixture (android/tools/mock-machine.mjs). Silently
 * skips when the test bed is not running.
 *
 * Start the bed:
 *   node packages/relay-server/dist/index.js   (env: token, PORT=8787)
 *   node android/tools/mock-machine.mjs --relay ws://127.0.0.1:8787/v1/connect …
 * Then create .relay-local/{machine.txt,secret.txt} from a registered machine.
 */
private class ReplySeen : Exception()

class DSHLiveRelayTest {
    private fun bedAvailable(): Boolean = runCatching {
        Socket().use { it.connect(InetSocketAddress("127.0.0.1", 8787), 300) }
        true
    }.getOrDefault(false)

    private fun bedCredentials(): Pair<String, String>? {
        var dir: File? = File(System.getProperty("user.dir"))
        var base: File? = null
        while (dir != null) {
            if (File(dir, ".relay-local").isDirectory()) { base = File(dir, ".relay-local"); break }
            dir = dir.parentFile
        }
        base ?: return null
        val machine = File(base, "machine.txt")
        val secret = File(base, "secret.txt")
        if (!machine.exists() || !secret.exists()) return null
        return machine.readText().trim() to secret.readText().trim()
    }

    @Test
    fun pairConnectAndStreamAgainstLocalBed() = runBlocking {
        if (!bedAvailable()) {
            println("SKIP: relay test bed not running on 127.0.0.1:8787")
            return@runBlocking
        }
        val (machineId, secret) = bedCredentials() ?: run {
            println("SKIP: .relay-local credentials missing")
            return@runBlocking
        }

        // 1) REST pairing, exactly what PairingScreen drives.
        val base = DSHAPIClient.relayBaseURL("http://127.0.0.1:8787")
        val (profile, token) = DSHAPIClient(base)
            .pair(machineId, DSHPairingCredential.Secret(secret), "JVM-Integration-Test")
        assertTrue(profile.deviceId.isNotEmpty())
        assertTrue(token.isNotEmpty())

        // 2) WebSocket connect; the connection auto-resumes and the mock answers
        //    with connection.ready + a session snapshot.
        val connection = DSHWebSocketConnection(
            DSHWebSocketConfiguration(
                url = "ws://127.0.0.1:8787/v1/connect",
                bearerToken = token,
                deviceId = profile.deviceId,
                machineId = profile.machineId,
            ),
        )
        val events = connection.connect()
        val readySeen = withTimeoutOrNull(10_000) {
            events.first { it.type == "session.snapshot" }
        }
        assertTrue(readySeen != null, "expected session snapshot after resume")

        // 3) Send a prompt and fold the reply through the real reducer.
        val sessionId = "s-mock-1"
        connection.send(
            DSHCommand.sendPrompt(deviceId = profile.deviceId, machineId = profile.machineId,
                sessionId = sessionId, text = "integration check"),
        )
        var state = DSHStoreState()
        var sawCompleted = false
        try {
            withTimeout(10_000) {
                events.collect { event ->
                    state = DSHEventReducer.reduce(event, state)
                    val messages: List<DSHChatMessage> = state.messagesBySession[sessionId] ?: emptyList()
                    if (messages.any {
                            it.role == DSHMessageRole.assistant && it.markdown.contains("Mock reply")
                        }
                    ) {
                        sawCompleted = true
                        throw ReplySeen()
                    }
                }
            }
        } catch (_: ReplySeen) {
        } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
        }
        assertTrue(sawCompleted, "assistant reply never streamed through the reducer")
        connection.disconnect()
    }
}

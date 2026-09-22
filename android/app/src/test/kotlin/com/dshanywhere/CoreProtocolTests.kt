package com.dshanywhere

import com.dshanywhere.core.network.DSHExponentialBackoff
import com.dshanywhere.core.protocol.DSHChatMessage
import com.dshanywhere.core.protocol.DSHCommand
import com.dshanywhere.core.protocol.DSHEnvelope
import com.dshanywhere.core.protocol.DSHEvent
import com.dshanywhere.core.protocol.DSHEventKind
import com.dshanywhere.core.protocol.DSHJson
import com.dshanywhere.core.protocol.DSHMarkdown
import com.dshanywhere.core.protocol.DSHMarkdownBlock
import com.dshanywhere.core.protocol.DSHMessageRole
import com.dshanywhere.core.protocol.DSHPairingCredential
import com.dshanywhere.core.protocol.DSHPairingLink
import com.dshanywhere.core.protocol.DSHRelayMessage
import com.dshanywhere.core.protocol.DSHRelayPayloadMessage
import com.dshanywhere.core.protocol.DSHRelayRole
import com.dshanywhere.core.protocol.DSHToolActivity
import com.dshanywhere.core.protocol.DSHTranscriptEntry
import com.dshanywhere.core.protocol.transcriptEntries
import com.dshanywhere.core.protocol.withTaskTimelines
import com.dshanywhere.core.store.DSHEventReducer
import com.dshanywhere.core.store.DSHStoreState
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.test.assertNull
import kotlin.test.assertTrue

class EnvelopeAndCommandTest {
    @Test fun envelopeOmitsNullSessionIdButKeepsVersion() {
        val envelope = DSHEnvelope(
            version = 1, messageId = "m1", deviceId = "d1", machineId = "mac1",
            sequence = 7, timestamp = 1000, type = "usage.updated",
            payload = DSHJson.parseToJsonElement("""{"sessionId":"s","usage":{}}"""),
        )
        val text = DSHJson.encodeToString(DSHEnvelope.serializer(), envelope)
        val obj = DSHJson.parseToJsonElement(text).jsonObject
        assertTrue("version" in obj)
        // Optional-null fields must be *omitted*, not encoded as nulls, so the
        // relay's strict schemas accept the envelope. (Key-level check, not a
        // substring check: the payload itself may carry a sessionId field.)
        assertTrue("sessionId" !in obj)
    }

    @Test fun resumeCommandCarriesLastSequence() {
        val command = DSHCommand.resume(deviceId = "d", machineId = "m", lastSequence = 42)
        assertEquals("connection.resume", command.type)
        val payload = command.payload.jsonObject["lastSequence"]!!.jsonPrimitive.content
        assertEquals("42", payload)
    }

    @Test fun multipartPromptKeepsTextInsideContentArray() {
        val attachment = DSHJson.parseToJsonElement("""{"type":"file","receiptId":"r1"}""")
        val command = DSHCommand.sendPrompt(
            deviceId = "d", machineId = "m", sessionId = "s", text = "hello",
            attachments = listOf(attachment),
        )
        val payload = command.payload.jsonObject
        assertEquals("queue", payload["mode"]!!.jsonPrimitive.content)
        val content = payload["content"]!!.toString()
        assertTrue(content.contains("\"type\":\"text\""))
        assertTrue("\"hello\"" in content)
        assertTrue("r1" in content.toString())
    }

    @Test fun openSessionRequestsStreamingDurableHistory() {
        val command = DSHCommand.openSession("d", "m", "s")
        assertEquals("session.open", command.type)
        assertEquals("s", command.sessionId)
        assertEquals("s", command.payload.jsonObject["sessionId"]!!.jsonPrimitive.content)
        assertEquals("true", command.payload.jsonObject["streaming"]!!.jsonPrimitive.content)
    }

    @Test fun remoteWorkspaceCommandsUseMacOwnedPaths() {
        val list = DSHCommand.directoryList("d", "m", "/Users/me")
        assertEquals("directory.list", list.type)
        assertEquals("/Users/me", list.payload.jsonObject["path"]!!.jsonPrimitive.content)
        val create = DSHCommand.createWorkspace("d", "m", "/Users/me/project")
        assertEquals("workspace.create", create.type)
        assertEquals("/Users/me/project", create.payload.jsonObject["path"]!!.jsonPrimitive.content)
        assertEquals("mode.catalog", DSHCommand.modeCatalog("d", "m").type)
    }
}

class RelayMessageTest {
    @Test fun parsesAllFourRelayTypes() {
        assertTrue(DSHRelayMessage.parse("""{"type":"relay.ready","machineId":"m","role":"device","connectionId":"c","serverTime":1}""") is DSHRelayMessage.Ready)
        assertTrue(DSHRelayMessage.parse("""{"type":"relay.presence","machineId":"m","role":"machine","online":true,"serverTime":1}""") is DSHRelayMessage.Presence)
        assertTrue(DSHRelayMessage.parse("""{"type":"relay.error","code":"x","message":"y"}""") is DSHRelayMessage.Error)
        val payload = """{"type":"relay.payload","machineId":"m","messageId":"p","sender":"machine","body":{}}"""
        assertTrue(DSHRelayMessage.parse(payload) is DSHRelayMessage.Payload)
        assertNull(DSHRelayMessage.parse("""{"type":"bogus"}"""))
    }

    @Test fun commandWrappingRoundTripsThroughPayload() {
        val command = DSHCommand.listSessions(deviceId = "d", machineId = "m", includeArchived = true)
        val wrapped = DSHRelayPayloadMessage.wrappingCommand("m", DSHRelayRole.device, command)
        // Regression: `type` must survive `encodeDefaults = false`. A defaulted
        // property whose value equals its default is omitted from the JSON, and
        // the relay then rejects the message as schema-invalid — the client
        // silently never receives an event.
        assertTrue("\"type\":\"relay.payload\"" in wrapped.encodeText())
        val decoded = DSHJson.decodeFromString(DSHRelayPayloadMessage.serializer(), wrapped.encodeText())
        val body = decoded.body.jsonObject
        assertEquals("session.list", body["type"]!!.jsonPrimitive.content)
        assertTrue("includeArchived" in body.toString())
        assertNull(wrapped.encodeText().let { Regex("\"targetDeviceId\"").find(it) })
    }
}

class EventKindTest {
    private fun event(type: String, payloadJson: String, sequence: Long = 1): DSHEvent =
        DSHEvent(
            DSHEnvelope(
                version = 1, messageId = "e-$sequence", deviceId = "d", machineId = "m",
                sessionId = "s", sequence = sequence, timestamp = 0, type = type,
                payload = DSHJson.parseToJsonElement(payloadJson),
            ),
        )

    @Test fun knownTypesDecodeToKinds() {
        assertTrue(event("connection.ready", "{}").kind is DSHEventKind.ConnectionReady)
        val snapshot = event("session.snapshot", """[{"id":"s1","title":"t","updatedAt":5}]""")
        assertEquals("s1", (snapshot.kind as DSHEventKind.SessionSnapshot).sessions.single().id)
        val delta = event("assistant.message.delta", """{"messageId":"m","text":"hi"}""")
        assertEquals("hi", (delta.kind as DSHEventKind.AssistantMessageDelta).delta.text)
        val workspaces = event("workspace.catalog",
            """{"workspaces":[{"id":"w","title":"Project","path":"/tmp/p"}]}""")
        assertEquals("Project", (workspaces.kind as DSHEventKind.WorkspaceCatalog).workspaces.single().name)
    }

    @Test fun unknownAndMalformedFallToUnknown() {
        assertTrue(event("some.future.event", """{"whatever":1}""").kind is DSHEventKind.Unknown)
        // Missing required fields must not throw; payload stays on the envelope.
        assertTrue(event("assistant.message.delta", """{"text":"no id"}""").kind is DSHEventKind.Unknown)
    }
}

class ReducerTest {
    private fun reduce(state: DSHStoreState, vararg events: DSHEvent): DSHStoreState =
        DSHEventReducer.reduceAll(events.toList(), state)

    private fun envelope(seq: Long, type: String, payload: String, session: String? = "s") =
        DSHEvent(DSHEnvelope(1, "m$seq", "d", "mac", session, seq, 0, type, DSHJson.parseToJsonElement(payload)))

    @Test fun staleEventsAreIgnoredButEpochResetIsHonoured() {
        var state = reduce(DSHStoreState(),
            envelope(5, "turn.state.changed", """{"sessionId":"s","state":"active"}"""))
        state = reduce(state, envelope(3, "turn.state.changed", """{"sessionId":"s","state":"active"}"""))
        assertEquals(mapOf("s" to "active"), state.turnStateBySession)
        assertEquals(5, state.lastSequence)
        // connection.ready at a lower sequence opens a new epoch.
        state = reduce(state, envelope(1, "connection.ready", "{}"))
        assertEquals(1, state.lastSequence)
        assertTrue(state.connectionState is com.dshanywhere.core.network.DSHConnectionState.Connected)
    }

    @Test fun sessionSnapshotAlsoResetsEpoch() {
        val state = reduce(DSHStoreState(lastSequence = 9),
            envelope(2, "session.snapshot", "[]"))
        assertTrue(state.hasLoadedSessions)
        assertEquals(2, state.lastSequence)
    }

    @Test fun deltasAccumulateAndCompletionKeepsReasoningAndStartSequence() {
        var state = DSHStoreState()
        state = reduce(state, envelope(1, "assistant.reasoning", """{"messageId":"a","text":"thinking"}"""))
        state = reduce(state, envelope(2, "assistant.message.delta", """{"messageId":"a","text":"Hel"}"""))
        state = reduce(state, envelope(3, "assistant.message.delta", """{"messageId":"a","text":"lo"}"""))
        state = reduce(state, envelope(9, "assistant.message.completed",
            """{"id":"a","role":"assistant","markdown":"Hello"}"""))
        val message = state.messagesBySession.getValue("s").single()
        assertEquals("Hello", message.markdown)
        assertEquals("thinking", message.reasoning)
        // Completion keeps where the message *started*: the reasoning event at
        // seq 1 created the row, and neither the delta nor the completion
        // re-stamps it (matches the Swift reducer exactly).
        assertEquals(1, message.sequence)
    }

    @Test fun toolCompletedKeepsOriginalSequence() {
        var state = DSHStoreState()
        state = reduce(state, envelope(4, "tool.started", """{"id":"t","name":"bash","status":"running"}"""))
        state = reduce(state, envelope(8, "tool.completed", """{"id":"t","name":"bash","status":"completed"}"""))
        state = reduce(state, envelope(9, "tool.started", """{"id":"u","name":"read","status":"running"}"""))
        val tools = state.toolsBySession.getValue("s")
        assertEquals(4, tools.first { it.id == "t" }.sequence)
        assertEquals(9, tools.first { it.id == "u" }.sequence)
    }

    @Test fun historicalTurnStateCannotSettleLiveTurn() {
        var state = reduce(DSHStoreState(),
            envelope(1, "turn.state.changed", """{"sessionId":"s","state":"running"}"""))
        val historical = DSHEvent(DSHEnvelope(
            version = 1, messageId = "m2", deviceId = "d", machineId = "mac",
            sessionId = "s", sequence = 2, timestamp = 100,
            type = "turn.state.changed",
            payload = DSHJson.parseToJsonElement("""{"sessionId":"s","state":"completed"}"""),
            historyBatchId = "history-1",
        ))
        state = reduce(state, historical)
        assertEquals("running", state.turnStateBySession["s"])
    }

    @Test fun liveTurnCompletionStampsOneTaskEnd() {
        var state = reduce(DSHStoreState(),
            DSHEvent(DSHEnvelope(1, "u", "d", "mac", "s", 1, 1_000,
                "user.message.accepted", DSHJson.parseToJsonElement(
                    """{"id":"u","role":"user","markdown":"go"}"""))),
            envelope(2, "turn.state.changed", """{"sessionId":"s","state":"running"}"""),
            DSHEvent(DSHEnvelope(1, "a", "d", "mac", "s", 3, 1_500,
                "assistant.message.completed", DSHJson.parseToJsonElement(
                    """{"id":"a","role":"assistant","markdown":"done"}"""))),
        )
        state = reduce(state, DSHEvent(DSHEnvelope(1, "end", "d", "mac", "s", 4, 4_000,
            "turn.state.changed", DSHJson.parseToJsonElement(
                """{"sessionId":"s","state":"completed"}"""))))
        assertEquals(4_000, state.messagesBySession.getValue("s").last().taskCompletedAt)
    }

    @Test fun approvalsAndQuestionsDedupeAndRemove() {
        var state = DSHStoreState()
        val approval = """{"id":"ap","sessionId":"s","toolName":"bash","reason":"why"}"""
        state = reduce(state, envelope(1, "approval.requested", approval))
        state = reduce(state, envelope(2, "approval.requested", approval))
        assertEquals(1, state.pendingApprovals.size)
        state = reduce(state, envelope(3, "approval.resolved", """{"id":"ap","allowed":true}"""))
        assertTrue(state.pendingApprovals.isEmpty())
    }

    @Test fun usagePermissionMetadataUpdateTheSessionsList() {
        val sessions = """[{"id":"s","title":"t","updatedAt":1,"usage":{"totalTokens":1},"permissionMode":"workspace-write","model":"x"}]"""
        var state = reduce(DSHStoreState(), envelope(1, "session.snapshot", sessions))
        state = reduce(state, envelope(2, "usage.updated", """{"sessionId":"s","usage":{"totalTokens":42}}"""))
        assertEquals(42.0, state.sessions.single().usage?.totalTokens)
        state = reduce(state, envelope(3, "permission.updated", """{"sessionId":"s","mode":"danger-full-access"}"""))
        assertEquals("danger-full-access", state.sessions.single().permissionMode)
        state = reduce(state, envelope(4, "session.metadata.updated", """{"sessionId":"s","model":"new"}"""))
        assertEquals("new", state.sessions.single().model)
        assertEquals("t", state.sessions.single().title)
    }

    // --- transport / presence control events (ported from the iOS additions) ---

    private fun control(type: String, payloadJson: String) =
        DSHEvent(
            DSHEnvelope(
                version = 1, messageId = "c-${type}-${payloadJson.hashCode()}", deviceId = "d",
                machineId = "mac", sessionId = null, sequence = 0, timestamp = 0,
                type = type, payload = DSHJson.parseToJsonElement(payloadJson),
            ),
        )

    @Test fun controlEventsBypassTheReplayWindow() {
        var state = reduce(DSHStoreState(lastSequence = 7),
            control("transport.state", """{"state":"connecting"}"""))
        // The out-of-band signal must not roll back or advance the window.
        assertEquals(7, state.lastSequence)
        assertEquals(com.dshanywhere.core.network.DSHConnectionState.Connecting, state.transportState)
        assertEquals(com.dshanywhere.core.network.DSHConnectionState.Connecting, state.connectionState)
        // A real event at sequence 8 still applies afterwards.
        state = reduce(state, envelope(8, "turn.state.changed", """{"sessionId":"s","state":"active"}"""))
        assertEquals(8, state.lastSequence)
    }

    @Test fun transportStateClearsPresenceAndBridgeWhenNotConnected() {
        var state = reduce(DSHStoreState(),
            envelope(1, "connection.ready", "{}"))
        assertEquals(true, state.machineOnline)
        assertEquals(true, state.bridgeReachable)
        state = reduce(state, control("transport.state", """{"state":"reconnecting","attempt":2}"""))
        assertEquals(false, state.machineOnline)
        assertNull(state.bridgeReachable)
        assertEquals(com.dshanywhere.core.network.DSHConnectionState.Reconnecting(2), state.connectionState)
    }

    @Test fun machinePresenceDrivesConnectionStateAndBridge() {
        var state = reduce(DSHStoreState(), envelope(1, "connection.ready", "{}"))
        // Presence false always clears bridge reachability.
        state = reduce(state, control("machine.presence", "false"))
        assertEquals(false, state.machineOnline)
        assertNull(state.bridgeReachable)
        assertEquals(com.dshanywhere.core.network.DSHConnectionState.Disconnected, state.connectionState)
        // Presence true connects, but the bridge stays unknown until answered.
        state = reduce(state, control("machine.presence", "true"))
        assertEquals(true, state.machineOnline)
        assertEquals(com.dshanywhere.core.network.DSHConnectionState.Connected, state.connectionState)
        assertNull(state.bridgeReachable)
        // A snapshot proves the bridge answered.
        state = reduce(state, envelope(2, "session.snapshot", "[]"))
        assertEquals(true, state.bridgeReachable)
    }

    @Test fun bridgeFailureMarksBridgeUnreachable() {
        val state = reduce(DSHStoreState(),
            envelope(1, "connection.ready", "{}"),
            envelope(2, "protocol.error", """{"code":"bridge-request-failed","message":"nope","retryable":true}"""))
        assertEquals(false, state.bridgeReachable)
        assertEquals(true, state.machineOnline)
    }

    @Test fun malformedControlPayloadsLeaveStateUntouched() {
        // An undecodable control payload falls back to `.unknown`, which — like
        // every non-control event — still passes the sequence gate. Since
        // controls carry sequence 0, they are dropped rather than recorded.
        // (The Swift reducer behaves identically.)
        val state = reduce(DSHStoreState(), control("transport.state", """{"state":"wat"}"""))
        assertEquals(0, state.unknownEvents.size)
        assertEquals(com.dshanywhere.core.network.DSHConnectionState.Disconnected, state.transportState)
        // A decodable one still lands, even at sequence 0.
        val applied = reduce(DSHStoreState(), control("transport.state", """{"state":"connected"}"""))
        assertEquals(com.dshanywhere.core.network.DSHConnectionState.Connected, applied.transportState)
    }

    @Test fun protocolErrorsAreKeyedByEnvelopeMessageId() {
        val state = reduce(DSHStoreState(),
            envelope(1, "protocol.error", """{"code":"c","message":"boom","retryable":false}"""))
        assertEquals("boom", state.protocolErrorsByRequestID["m1"])
    }

    @Test fun unknownEventsKeepTheirEnvelope() {
        val state = reduce(DSHStoreState(), envelope(1, "future.event", """{"x":1}"""))
        assertEquals(1, state.unknownEvents.size)
        assertEquals("future.event", state.unknownEvents.single().type)
    }
}

class TranscriptTest {
    private fun msg(id: String, role: DSHMessageRole, seq: Long?, markdown: String = "m") =
        DSHChatMessage(id, role, markdown, sequence = seq)

    @Test fun assistantRunsGroupAndToolCallsBreakThem() {
        val messages = listOf(
            msg("u1", DSHMessageRole.user, 1),
            msg("a1", DSHMessageRole.assistant, 2),
            msg("a2", DSHMessageRole.assistant, 4),
        )
        val tools = listOf(DSHToolActivity("t1", "bash", "completed", sequence = 3))
        val entries = messages.transcriptEntries(tools)
        assertEquals(
            listOf("turn-u1", "turn-a1", "tool-t1", "turn-a2"),
            entries.map { it.id },
        )
        val lastTurn = entries[3] as DSHTranscriptEntry.Turn
        // The tool call at sequence 3 breaks the assistant run: a2 stands alone.
        assertContentEquals(listOf("a2"), lastTurn.block.messages.map { it.id })
        val firstTurn = entries[1] as DSHTranscriptEntry.Turn
        assertContentEquals(listOf("a1"), firstTurn.block.messages.map { it.id })
    }

    @Test fun tiesKeepArrivalOrder() {
        val messages = listOf(msg("u1", DSHMessageRole.user, 5), msg("a1", DSHMessageRole.assistant, 5))
        val entries = messages.transcriptEntries(emptyList())
        assertEquals(listOf("turn-u1", "turn-a1"), entries.map { it.id })
    }

    @Test fun blockFiltersEmptyBubblesAndMergesReasoning() {
        val block = com.dshanywhere.core.protocol.DSHTranscriptBlock(
            id = "b",
            messages = listOf(
                msg("a1", DSHMessageRole.assistant, 1).copy(reasoning = "one"),
                msg("a2", DSHMessageRole.assistant, 2, markdown = "").copy(reasoning = "  "),
            ),
        )
        assertEquals(1, block.visibleMessages.size)
        assertEquals("one", block.reasoning)
    }

    @Test fun oneTaskGetsOneTotalTimelineAcrossToolSplitReplies() {
        val messages = listOf(
            msg("u", DSHMessageRole.user, 1).copy(timestamp = 1_000),
            msg("a1", DSHMessageRole.assistant, 2),
            msg("a2", DSHMessageRole.assistant, 4).copy(taskCompletedAt = 5_000),
        )
        val entries = messages.transcriptEntries(
            listOf(DSHToolActivity("t", "read", "completed", sequence = 3)),
        ).withTaskTimelines()
        val assistant = entries.filterIsInstance<DSHTranscriptEntry.Turn>()
            .filterNot { it.block.isUserTurn }
        assertEquals(1, assistant.count { it.block.taskTimeline != null })
        assertEquals(4 to false, assistant.first().block.taskTimeline!!.duration())
    }
}

class MarkdownTest {
    @Test fun headingsAndParagraphsAndFences() {
        val blocks = DSHMarkdown.blocks(
            "# Title\n\nsome text\n```kotlin\nval x = 1\n```\n",
        )
        assertEquals(
            listOf(
                DSHMarkdownBlock.Kind.Heading(1, "Title"),
                DSHMarkdownBlock.Kind.Paragraph("some text"),
                DSHMarkdownBlock.Kind.Code("kotlin", "val x = 1"),
            ).map { it },
            blocks.map { it.kind },
        )
    }

    @Test fun unterminatedFenceStillEnds() {
        val blocks = DSHMarkdown.blocks("before\n```\ncode after")
        assertEquals(2, blocks.size)
        assertTrue(blocks.last().kind is DSHMarkdownBlock.Kind.Code)
    }

    @Test fun listsQuotesDividerAndTables() {
        val blocks = DSHMarkdown.blocks(
            """
            - one
            - two

            1. first
            2. second

            > quoted
            > more

            ---

            | a | b |
            | --- | --- |
            | 1 | 2 |
            """.trimIndent(),
        )
        val kinds = blocks.map { it.kind }
        assertEquals(
            listOf(
                DSHMarkdownBlock.Kind.Bullets(listOf("one", "two")),
                DSHMarkdownBlock.Kind.Numbers(listOf("first", "second")),
                DSHMarkdownBlock.Kind.Quote("quoted\nmore"),
                DSHMarkdownBlock.Kind.Divider,
                DSHMarkdownBlock.Kind.Table(listOf("a", "b"), listOf(listOf("1", "2"))),
            ),
            kinds,
        )
    }

    @Test fun hashtagIsNotAHeading() {
        val blocks = DSHMarkdown.blocks("#hashtag")
        assertTrue(blocks.single().kind is DSHMarkdownBlock.Kind.Paragraph)
    }
}

class PairingTest {
    @Test fun detectSeparatesCodeFromSecret() {
        assertEquals(DSHPairingCredential.Code("AB23CD45"), DSHPairingCredential.detect(" ab23cd45 "))
        val secret = "Zm9vYmFyX3RoaXNfaXNfYSBsb25nX3BhaXJpbmdfc2VjcmV0IQ"
        assertEquals(DSHPairingCredential.Secret(secret), DSHPairingCredential.detect(secret))
        assertNull(DSHPairingCredential.detect("   "))
        // 8 chars but with disallowed letters (0/O/1/I/L) is treated as a secret.
        assertTrue(DSHPairingCredential.detect("ABO1CD45") is DSHPairingCredential.Secret)
    }

    @Test fun linkRequiresCompleteValidFields() {
        val link = DSHPairingLink.parse(
            "dshanywhere://pair?relay=https%3A%2F%2Frelay.example&machineId=mac%2F1&code=AB23CD45",
        )
        assertEquals("https://relay.example", link?.relay)
        assertEquals("mac/1", link?.machineId)
        assertEquals(DSHPairingCredential.Code("AB23CD45"), link?.credential)
        assertNull(DSHPairingLink.parse("https://example.com/pair?relay=x&machineId=y&code=AB23CD45"))
        assertNull(DSHPairingLink.parse("dshanywhere://pair?relay=ftp://x&machineId=y&code=AB23CD45"))
        assertNull(DSHPairingLink.parse("dshanywhere://pair?relay=https%3A%2F%2Fx&machineId=y"))
    }

    @Test fun codeWinsOverSecretWhenBothPresent() {
        val link = DSHPairingLink.parse(
            "dshanywhere://pair?relay=https%3A%2F%2Fx&machineId=y&code=AB23CD45&secret=zzz",
        )
        assertEquals(DSHPairingCredential.Code("AB23CD45"), link?.credential)
    }
}

class BackoffTest {
    @Test fun doublesAndCaps() {
        val backoff = DSHExponentialBackoff()
        assertEquals(0, backoff.delayMillisFor(0))
        assertEquals(500, backoff.delayMillisFor(1))
        assertEquals(1000, backoff.delayMillisFor(2))
        assertEquals(30_000, backoff.delayMillisFor(100))
    }
}

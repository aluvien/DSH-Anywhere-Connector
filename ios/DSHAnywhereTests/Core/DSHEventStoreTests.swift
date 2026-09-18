import XCTest
@testable import DSHAnywhere

final class DSHEventStoreTests: XCTestCase {
    func testStreamingHeadroomConsumesMeasuredGrowthBeforeRefilling() {
        var plan = DSHStreamingHeadroomPlan()
        plan.record(streamID: "stream-live", size: CGSize(width: 320, height: 50))
        let stableShell = try! XCTUnwrap(plan.reservedReplyHeight)
        XCTAssertEqual(plan.reservedHeight, 80, accuracy: 0.01)

        // A real 24pt wrap consumes the capacity.  The rendered outer row
        // remains the same height instead of making the scroll view advance.
        plan.record(streamID: "stream-live", size: CGSize(width: 320, height: 74))
        XCTAssertEqual(try! XCTUnwrap(plan.reservedReplyHeight), stableShell, accuracy: 0.01)
        let remaining = plan.reservedHeight
        plan.prepareForNextChunk(streamID: "stream-live")
        XCTAssertEqual(plan.reservedHeight, remaining, accuracy: 0.01,
                       "Do not refill after every wrapped line")

        // A transient Markdown reflow can shrink content; its capacity is
        // returned, keeping the outer shell stable and bounded.
        plan.record(streamID: "stream-live", size: CGSize(width: 320, height: 62))
        XCTAssertEqual(try! XCTUnwrap(plan.reservedReplyHeight), stableShell, accuracy: 0.01)

        // Completion clears all artificial height, even if the turn has not
        // yet emitted its final state update.
        plan.begin(streamID: nil)
        XCTAssertNil(plan.reservedReplyHeight)
        XCTAssertEqual(plan.reservedHeight, 0)

        // A rotation / Dynamic Type relayout starts a fresh measurement rather
        // than carrying a portrait estimate into the new width.  Very tall
        // content remains capped so no blank page can appear.
        plan.record(streamID: "stream-live", size: CGSize(width: 320, height: 50))
        plan.record(streamID: "stream-live", size: CGSize(width: 480, height: 20))
        XCTAssertEqual(plan.reservedHeight, 32, accuracy: 0.01)
        plan.record(streamID: "stream-next", size: CGSize(width: 480, height: 20))
        XCTAssertEqual(plan.streamID, "stream-next")
        XCTAssertEqual(plan.reservedHeight, 32, accuracy: 0.01,
                       "A new delta ID must not inherit the previous reply's capacity")
        var capped = DSHStreamingHeadroomPlan()
        capped.record(streamID: "stream-tall", size: CGSize(width: 320, height: 500))
        XCTAssertLessThanOrEqual(capped.reservedHeight, 96)
    }

    func testOnlyCurrentTransientStreamMessageCanReserveHeadroom() {
        let user = DSHChatMessage(id: "user", role: .user, markdown: "go", sequence: 10)
        let legacy = DSHChatMessage(id: "assistant-final", role: .assistant,
                                    markdown: "already durable", sequence: 11)
        XCTAssertNil(DSHStreamingMessageProjection.active(messages: [user, legacy], turnState: "running"))

        let oldTransient = DSHChatMessage(id: "stream-old", role: .assistant,
                                          markdown: "old", sequence: 9)
        XCTAssertNil(DSHStreamingMessageProjection.active(messages: [user, oldTransient], turnState: "running"))

        let live = DSHChatMessage(id: "stream-live", role: .assistant,
                                  markdown: "partial", sequence: 12)
        XCTAssertEqual(DSHStreamingMessageProjection.active(messages: [user, live], turnState: "running")?.streamID,
                       "stream-live")

        let completed = DSHChatMessage(id: "canonical", role: .assistant,
                                       markdown: "final", sequence: 12,
                                       replacesMessageId: "stream-live")
        XCTAssertNil(DSHStreamingMessageProjection.active(messages: [user, completed], turnState: "running"))
    }

    @MainActor
    func testStreamingCompletionKeepsCanonicalIDAndDoesNotResurrectPartialOnReplay() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        func apply(_ type: String, _ sequence: Int64, _ payload: [String: DSHJSONValue]) {
            reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: "e-\(sequence)", deviceId: "d", machineId: "m",
                sessionId: "s", sequence: sequence, type: type, payload: .object(payload))), into: &state)
        }
        apply("assistant.message.delta", 1, ["messageId": .string("partial"), "text": .string("Hello")])
        XCTAssertEqual(state.messagesBySession["s"]?.first?.markdown, "Hello")
        apply("assistant.message.delta", 2, ["messageId": .string("partial"), "text": .string(" world")])
        XCTAssertEqual(state.messagesBySession["s"]?.first?.markdown, "Hello world")
        reducer.reduce(historyEvent(type: "history.started", sequence: 3), into: &state)
        apply("assistant.reasoning", 4, ["messageId": .string("canonical"), "text": .string("Reasoning")])
        apply("assistant.message.completed", 5, ["id": .string("canonical"), "role": .string("assistant"),
            "markdown": .string("Hello world!"), "replacesMessageId": .string("partial")])
        reducer.reduce(historyEvent(type: "history.completed", sequence: 6), into: &state)
        XCTAssertEqual(state.messagesBySession["s"]?.map(\.id), ["canonical"])
        XCTAssertEqual(state.messagesBySession["s"]?.first?.markdown, "Hello world!")
        XCTAssertEqual(state.messagesBySession["s"]?.first?.reasoning, "Reasoning")
        XCTAssertEqual(state.messagesBySession["s"]?.first?.sequence, 1)
        apply("assistant.message.completed", 7, ["id": .string("canonical"), "role": .string("assistant"), "markdown": .string("Hello world!")])
        XCTAssertEqual(state.messagesBySession["s"]?.count, 1)
    }

    @MainActor
    func testAbandonedStreamIsRemovedFromLiveAndHistoryCarry() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: "d", deviceId: "d", machineId: "m", sessionId: "s", sequence: 1,
            type: "assistant.message.delta", payload: .object(["messageId": .string("partial"), "text": .string("obsolete")]))), into: &state)
        reducer.reduce(historyEvent(type: "history.started", sequence: 2), into: &state)
        reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: "x", deviceId: "d", machineId: "m", sessionId: "s", sequence: 3,
            type: "assistant.message.discarded", payload: .object(["messageId": .string("partial")]))), into: &state)
        reducer.reduce(historyEvent(type: "history.completed", sequence: 4), into: &state)
        XCTAssertTrue(state.messagesBySession["s", default: []].isEmpty)
    }

    @MainActor
    func testSessionBecomesUnreadOnlyAfterNewerActivity() {
        UserDefaults.standard.removeObject(forKey: DSHAppModel.lastReadSessionsKey)
        UserDefaults.standard.removeObject(forKey: DSHAppModel.unreadBaselineKey)
        defer {
            UserDefaults.standard.removeObject(forKey: DSHAppModel.lastReadSessionsKey)
            UserDefaults.standard.removeObject(forKey: DSHAppModel.unreadBaselineKey)
        }

        let model = DSHAppModel.preview()
        model.selectedSessionID = nil
        guard let session = model.sessions.first else {
            return XCTFail("Preview session is missing")
        }
        model.markSessionRead(session.id)
        XCTAssertFalse(model.isSessionUnread(session))

        var updated = session
        updated.updatedAt = Int64(Date().timeIntervalSince1970 * 1_000) + 1_000
        XCTAssertTrue(model.isSessionUnread(updated))
    }

    @MainActor
    func testConfirmedMessageHideSurvivesAViewModelReload() {
        UserDefaults.standard.removeObject(forKey: DSHAppModel.hiddenMessagesKey)
        defer { UserDefaults.standard.removeObject(forKey: DSHAppModel.hiddenMessagesKey) }

        let model = DSHAppModel.preview()
        model.hideMessage("preview-user", in: "preview-session")

        let visibleAfterDelete = model.transcriptEntries(for: "preview-session").flatMap { entry -> [String] in
            guard case .turn(let block) = entry else { return [] }
            return block.messages.map(\.id)
        }
        XCTAssertFalse(visibleAfterDelete.contains("preview-user"))

        let reloaded = DSHAppModel.preview()
        let visibleAfterReload = reloaded.transcriptEntries(for: "preview-session").flatMap { entry -> [String] in
            guard case .turn(let block) = entry else { return [] }
            return block.messages.map(\.id)
        }
        XCTAssertFalse(visibleAfterReload.contains("preview-user"))
        XCTAssertTrue(visibleAfterReload.contains("preview-assistant"))
    }

    func testReducerStreamsAssistantDeltaAndIgnoresDuplicateSequence() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        let first = DSHEvent(envelope: DSHEnvelope(messageId: "1", deviceId: "d", machineId: "m",
                                                   sessionId: "s", sequence: 1, type: "assistant.message.delta",
                                                   payload: .object(["messageId": .string("a"), "text": .string("Hel")])))
        let duplicate = DSHEvent(envelope: DSHEnvelope(messageId: "2", deviceId: "d", machineId: "m",
                                                       sessionId: "s", sequence: 1, type: "assistant.message.delta",
                                                       payload: .object(["messageId": .string("a"), "text": .string("lo")])))
        reducer.reduce(first, into: &state)
        reducer.reduce(duplicate, into: &state)
        XCTAssertEqual(state.lastSequence, 1)
        XCTAssertEqual(state.messagesBySession["s"]?.first?.markdown, "Hel")
    }

    @MainActor
    func testStreamingMarkdownRendererMatchesFullParserAcrossBlockBoundaries() {
        let chunks = [
            "Hello", " world", " with `inline", " code`", "\n\n# Heading", "\n",
            "\n- first", "\n- second", "\n\n```swift", "\nlet value = 1", "\n```",
            "\n\n| left | right |", "\n| --- | --- |", "\n| 1 | 2 |", " tail"
        ]
        var text = ""
        let renderer = DSHMarkdownBlockRenderer(text: text)

        for chunk in chunks {
            text += chunk
            renderer.update(text: text)
            XCTAssertEqual(renderer.blocks, DSHMarkdown.blocks(from: text),
                           "Incremental rendering diverged after chunk: \(chunk)")
        }

        let parseCountAfterChanges = renderer.parseCount
        renderer.update(text: text)
        XCTAssertEqual(renderer.parseCount, parseCountAfterChanges,
                       "An unchanged body pass must reuse its parsed blocks")

        // A stream's durable completion replaces the temporary text in the
        // same rendered row.  Its document must be parsed from the canonical
        // value, not a stale partial prefix.
        let canonical = "# Final\n\n```swift\nlet done = true\n```"
        renderer.update(text: canonical)
        XCTAssertEqual(renderer.blocks, DSHMarkdown.blocks(from: canonical))
        XCTAssertEqual(renderer.parseCount, parseCountAfterChanges + 1)
    }

    func testUnknownEventsAreRetained() {
        var state = DSHStoreState()
        let event = DSHEvent(envelope: DSHEnvelope(messageId: "u", deviceId: "d", machineId: "m",
                                                   sequence: 2, type: "new.event",
                                                   payload: .string("preserve me")))
        DSHEventReducer().reduce(event, into: &state)
        XCTAssertEqual(state.unknownEvents, [event.envelope])
    }

    func testConnectionReadyStartsANewSequenceEpochAfterBridgeRestart() {
        var state = DSHStoreState()
        state.lastSequence = 42
        let ready = DSHEvent(envelope: DSHEnvelope(
            messageId: "ready", deviceId: "d", machineId: "m", sequence: 1,
            type: "connection.ready", payload: .object([:])
        ))
        DSHEventReducer().reduce(ready, into: &state)
        XCTAssertEqual(state.lastSequence, 1)
        XCTAssertEqual(state.connectionState, .connected)
    }

    func testStaleLowerSnapshotCannotReplaceNewerAuthoritativeSessions() {
        var state = DSHStoreState()
        state.lastSequence = 42
        state.sessions = [DSHSessionSummary(id: "fresh", title: "Fresh", updatedAt: 42)]
        let stale = DSHEvent(envelope: DSHEnvelope(
            messageId: "replayed", deviceId: "d", machineId: "m", sequence: 3,
            type: "session.snapshot", payload: .array([
                .object(["id": .string("stale"), "title": .string("Stale"), "updatedAt": .number(3)]),
            ])
        ))

        DSHEventReducer().reduce(stale, into: &state)

        XCTAssertEqual(state.lastSequence, 42)
        XCTAssertEqual(state.sessions.map(\.id), ["fresh"])
    }

    func testCorrelatedLowerSnapshotStartsNewEpochAfterConnectorRestart() {
        var state = DSHStoreState()
        state.lastSequence = 42
        state.sessions = [DSHSessionSummary(id: "old", title: "Old", updatedAt: 42)]
        let fresh = DSHEvent(envelope: DSHEnvelope(
            messageId: "requested", deviceId: "d", machineId: "m", sequence: 1,
            type: "session.snapshot", payload: .array([
                .object(["id": .string("new"), "title": .string("New"), "updatedAt": .number(1)]),
            ])
        ), establishesSequenceEpoch: true)

        DSHEventReducer().reduce(fresh, into: &state)

        XCTAssertEqual(state.lastSequence, 1)
        XCTAssertEqual(state.sessions.map(\.id), ["new"])
        XCTAssertTrue(state.hasLoadedSessions)
    }

    func testRelayControlsUpdateReachabilityOutsideConnectorSequence() {
        var state = DSHStoreState()
        state.lastSequence = 42
        state.transportState = .connected
        state.machineOnline = true
        state.connectionState = .connected

        let reconnecting = DSHEvent(envelope: DSHEnvelope(
            messageId: "transport", deviceId: "d", machineId: "m", sequence: 0,
            type: "transport.state",
            payload: .object(["state": .string("reconnecting"), "attempt": .number(1)])
        ))
        DSHEventReducer().reduce(reconnecting, into: &state)
        XCTAssertEqual(state.lastSequence, 42)
        XCTAssertEqual(state.transportState, .reconnecting(attempt: 1))
        XCTAssertFalse(state.machineOnline)
        XCTAssertNil(state.bridgeReachable)

        let relayConnected = DSHEvent(envelope: DSHEnvelope(
            messageId: "relay", deviceId: "d", machineId: "m", sequence: 0,
            type: "transport.state", payload: .object(["state": .string("connected")])
        ))
        let machineOnline = DSHEvent(envelope: DSHEnvelope(
            messageId: "presence", deviceId: "d", machineId: "m", sequence: 0,
            type: "machine.presence", payload: .bool(true)
        ))
        DSHEventReducer().reduce(relayConnected, into: &state)
        DSHEventReducer().reduce(machineOnline, into: &state)
        XCTAssertEqual(state.lastSequence, 42)
        XCTAssertEqual(state.transportState, .connected)
        XCTAssertTrue(state.machineOnline)
        XCTAssertNil(state.bridgeReachable)
        XCTAssertEqual(state.connectionState, .connected)
    }

    func testBridgeFailureOverridesConnectorPresenceUntilBridgeRecovers() {
        var state = DSHStoreState()
        state.transportState = .connected
        state.machineOnline = true
        let reducer = DSHEventReducer()
        let failure = DSHEvent(envelope: DSHEnvelope(
            messageId: "failed", deviceId: "d", machineId: "m", sequence: 1,
            type: "protocol.error",
            payload: .object([
                "code": .string("bridge-request-failed"),
                "message": .string("Local DSH bridge request failed"),
                "retryable": .bool(true),
            ])
        ))
        reducer.reduce(failure, into: &state)
        XCTAssertEqual(state.bridgeReachable, false)

        let ready = DSHEvent(envelope: DSHEnvelope(
            messageId: "ready-again", deviceId: "d", machineId: "m", sequence: 2,
            type: "connection.ready", payload: .object([:])
        ))
        reducer.reduce(ready, into: &state)
        XCTAssertEqual(state.bridgeReachable, true)
    }

    func testAuthoritativeSnapshotStartsANewSequenceEpochAfterConnectorRestart() {
        var state = DSHStoreState()
        state.lastSequence = 42
        state.sessions = [DSHSessionSummary(id: "stale", title: "Stale", updatedAt: 1)]
        let snapshot = DSHEvent(envelope: DSHEnvelope(
            messageId: "snapshot", deviceId: "d", machineId: "m", sequence: 1,
            type: "session.snapshot", payload: .array([
                .object(["id": .string("current"), "title": .string("Current"), "updatedAt": .number(2)]),
            ])
        ), establishesSequenceEpoch: true)
        DSHEventReducer().reduce(snapshot, into: &state)
        XCTAssertEqual(state.lastSequence, 1)
        XCTAssertEqual(state.sessions.map(\.id), ["current"])
    }

    func testApprovalResolvesExactlyOnce() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        let requested = DSHEvent(envelope: DSHEnvelope(messageId: "a", deviceId: "d", machineId: "m",
                                                        sessionId: "s", sequence: 1, type: "approval.requested",
                                                        payload: .object(["id": .string("approval"), "sessionId": .string("s"),
                                                                         "toolName": .string("shell"), "reason": .string("run")])))
        let resolved = DSHEvent(envelope: DSHEnvelope(messageId: "b", deviceId: "d", machineId: "m",
                                                       sessionId: "s", sequence: 2, type: "approval.resolved",
                                                       payload: .object(["id": .string("approval"), "allowed": .bool(false)])))
        reducer.reduce(requested, into: &state); reducer.reduce(resolved, into: &state)
        XCTAssertTrue(state.pendingApprovals.isEmpty)
    }

    func testQuestionAskedSurvivesUntilTheBridgeResolvesIt() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        let asked = DSHEvent(envelope: DSHEnvelope(
            messageId: "q", deviceId: "d", machineId: "m", sessionId: "s", sequence: 1,
            type: "question.asked",
            payload: .object([
                "id": .string("question_1"),
                "sessionId": .string("s"),
                "questions": .array([
                    .object([
                        "id": .string("mode"),
                        "question": .string("Which mode?"),
                        "options": .array([
                            .object(["label": .string("Fast")]),
                            .object(["label": .string("Careful")]),
                        ]),
                    ]),
                ]),
            ])
        ))
        reducer.reduce(asked, into: &state)

        // The tappable options must survive decoding, since they are the whole
        // point of answering from the phone.
        XCTAssertEqual(state.pendingQuestions.count, 1)
        XCTAssertEqual(state.pendingQuestions.first?.questions.first?.options?.map(\.label),
                       ["Fast", "Careful"])

        // A replayed duplicate must not stack a second card.
        reducer.reduce(asked, into: &state)
        XCTAssertEqual(state.pendingQuestions.count, 1)

        let resolved = DSHEvent(envelope: DSHEnvelope(
            messageId: "q2", deviceId: "d", machineId: "m", sessionId: "s", sequence: 2,
            type: "question.resolved",
            payload: .object(["id": .string("question_1"), "sessionId": .string("s")])
        ))
        reducer.reduce(resolved, into: &state)
        XCTAssertTrue(state.pendingQuestions.isEmpty)
    }

    func testReasoningIsKeptOutOfTheAnswerAndSurvivesCompletion() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        let reasoning = DSHEvent(envelope: DSHEnvelope(
            messageId: "r", deviceId: "d", machineId: "m", sessionId: "s", sequence: 1,
            type: "assistant.reasoning",
            payload: .object(["messageId": .string("a"), "text": .string("Let me think.")])
        ))
        let completed = DSHEvent(envelope: DSHEnvelope(
            messageId: "c", deviceId: "d", machineId: "m", sessionId: "s", sequence: 2,
            type: "assistant.message.completed",
            payload: .object(["id": .string("a"), "role": .string("assistant"), "markdown": .string("The answer.")])
        ))
        reducer.reduce(reasoning, into: &state)
        reducer.reduce(completed, into: &state)

        let message = state.messagesBySession["s"]?.first
        XCTAssertEqual(message?.markdown, "The answer.")
        // Completion replaces the streaming partial, so it must carry the
        // reasoning forward rather than dropping it.
        XCTAssertEqual(message?.reasoning, "Let me think.")
    }

    func testSessionsOutsideEveryWorkspaceAreNotListed() {
        let sessions = [
            DSHSessionSummary(id: "a", title: "Real work", updatedAt: 30, workspaceName: "project-a"),
            DSHSessionSummary(id: "b", title: "Loose one", updatedAt: 20, cwd: "/tmp/one"),
            DSHSessionSummary(id: "c", title: "Loose two", updatedAt: 10, cwd: "/tmp/two"),
        ]

        let groups = sessions.groupedForList(.byWorkspace, showArchived: false)

        // They must not invent one workspace per directory *nor* collect into an
        // "Other" bucket: delegated subagent runs have no workspace either, so
        // that bucket mixed junk with real sessions.
        XCTAssertEqual(groups.map(\.title), ["project-a"])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["a"])
    }

    func testFlatModeAlsoOmitsSessionsWithNoWorkspace() {
        let sessions = [
            DSHSessionSummary(id: "a", title: "Real work", updatedAt: 30, workspaceName: "project-a"),
            DSHSessionSummary(id: "b", title: "Loose one", updatedAt: 40, cwd: "/tmp/one"),
        ]

        let groups = sessions.groupedForList(.flat, showArchived: false)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].sessions.map(\.id), ["a"])
    }

    func testFlatGroupingKeepsOneRecencySortedList() {
        let sessions = [
            DSHSessionSummary(id: "old", title: "Old", updatedAt: 1, workspaceName: "z"),
            DSHSessionSummary(id: "new", title: "New", updatedAt: 9, workspaceName: "a"),
        ]

        let groups = sessions.groupedForList(.flat, showArchived: false)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].sessions.map(\.id), ["new", "old"])
    }

    func testGroupingHonoursTheArchiveFilter() {
        let sessions = [
            DSHSessionSummary(id: "live", title: "Live", updatedAt: 2, workspaceName: "w"),
            DSHSessionSummary(id: "gone", title: "Gone", updatedAt: 1, workspaceName: "w", archived: true),
        ]

        XCTAssertEqual(sessions.groupedForList(.byWorkspace, showArchived: false)[0].sessions.map(\.id), ["live"])
        XCTAssertEqual(sessions.groupedForList(.byWorkspace, showArchived: true)[0].sessions.map(\.id), ["live", "gone"])
        XCTAssertTrue(sessions.filter { $0.archived == true }.groupedForList(.byWorkspace, showArchived: false).isEmpty)
    }

    func testWorkspaceOptionsAreDedupedAndSorted() {
        let sessions = [
            DSHSessionSummary(id: "a", title: "A", updatedAt: 3, workspaceId: "ws-b", workspaceName: "beta"),
            DSHSessionSummary(id: "b", title: "B", updatedAt: 2, workspaceId: "ws-a", workspaceName: "Alpha"),
            DSHSessionSummary(id: "c", title: "C", updatedAt: 1, workspaceId: "ws-b", workspaceName: "beta"),
            // Unfiled sessions contribute nothing to the picker.
            DSHSessionSummary(id: "d", title: "D", updatedAt: 0, cwd: "/tmp"),
        ]

        let options = sessions.workspaceOptions()

        XCTAssertEqual(options.map(\.id), ["ws-a", "ws-b"])
        XCTAssertEqual(options.map(\.name), ["Alpha", "beta"])
    }

    func testWorkspaceGroupsUseStableRegistryIDsForMutations() {
        let sessions = [
            DSHSessionSummary(id: "a", title: "A", updatedAt: 2,
                              workspaceId: "workspace-1", workspaceName: "Renamable"),
            DSHSessionSummary(id: "b", title: "B", updatedAt: 1,
                              workspaceId: "workspace-1", workspaceName: "Renamable"),
        ]

        let groups = sessions.groupedForList(.byWorkspace, showArchived: false)

        XCTAssertEqual(groups.map(\.id), ["workspace-1"])
        XCTAssertEqual(groups.map(\.title), ["Renamable"])
    }

    func testModelChangeIsStoredAsInlineTranscriptEntry() {
        var state = DSHStoreState()
        let event = DSHEvent(envelope: DSHEnvelope(
            messageId: "model-change", deviceId: "d", machineId: "m", sessionId: "s", sequence: 2,
            type: "session.model.changed",
            payload: .object([
                "sessionId": .string("s"),
                "previous": .object(["provider": .string("deepseek"), "model": .string("v4.1-flash")]),
                "current": .object(["provider": .string("deepseek"), "model": .string("v4.1-reasoner")]),
            ])
        ))

        DSHEventReducer().reduce(event, into: &state)
        let notice = try! XCTUnwrap(state.modelChangesBySession["s"]?.first)
        XCTAssertEqual(notice.sequence, 2)
        XCTAssertEqual(notice.previous?.model, "v4.1-flash")
        XCTAssertEqual(notice.current.model, "v4.1-reasoner")

        let entries = [DSHChatMessage(id: "answer", role: .assistant, markdown: "ok", sequence: 3)]
            .transcriptEntries(with: [], modelChanges: [notice])
        XCTAssertEqual(entries.map(\.id), ["model-change-s-2-deepseek-v4.1-reasoner", "turn-answer"])
    }

    func testModelChangesBeforeOneSendCollapseToTheFinalChoice() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()

        reducer.reduce(modelChangeEvent(model: "draft", sequence: 1), into: &state)
        reducer.reduce(modelChangeEvent(model: "balanced", sequence: 2), into: &state)
        reducer.reduce(modelChangeEvent(model: "focused", sequence: 3), into: &state)

        let notices = state.modelChangesBySession["s"] ?? []
        XCTAssertEqual(notices.map(\.current.model), ["focused"])
        XCTAssertEqual(notices.map(\.sequence), [3])
    }

    func testModelChangesAfterAcceptedSendStartANewNoticeBatch() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()

        reducer.reduce(modelChangeEvent(model: "draft", sequence: 1), into: &state)
        reducer.reduce(modelChangeEvent(model: "balanced", sequence: 2), into: &state)
        reducer.reduce(userMessageEvent(id: "question", text: "send this", sequence: 3), into: &state)
        reducer.reduce(modelChangeEvent(model: "focused", sequence: 4), into: &state)
        reducer.reduce(modelChangeEvent(model: "max", sequence: 5), into: &state)

        let notices = state.modelChangesBySession["s"] ?? []
        XCTAssertEqual(notices.map(\.current.model), ["balanced", "max"])
        XCTAssertEqual(notices.map(\.sequence), [2, 5])

        let entries = state.messagesBySession["s", default: []]
            .transcriptEntries(with: [], modelChanges: notices)
        XCTAssertEqual(entries.map(\.id), [
            "model-change-s-2-provider-balanced",
            "turn-question",
            "model-change-s-5-provider-max",
        ])
    }

    func testPermissionUpdateChangesSessionStateWithoutAddingTranscriptNotice() {
        var state = DSHStoreState()
        state.sessions = [DSHSessionSummary(id: "s", permissionMode: "read-only")]
        let event = DSHEvent(envelope: DSHEnvelope(
            messageId: "permission", deviceId: "d", machineId: "m", sessionId: "s", sequence: 1,
            type: "permission.updated",
            payload: .object([
                "sessionId": .string("s"),
                "mode": .string("danger-full-access"),
            ])
        ))

        DSHEventReducer().reduce(event, into: &state)

        XCTAssertEqual(state.permissionBySession["s"]?.mode, "danger-full-access")
        XCTAssertEqual(state.sessions.first?.permissionMode, "danger-full-access")
        XCTAssertTrue(state.messagesBySession["s", default: []].isEmpty)
        XCTAssertTrue(state.modelChangesBySession["s", default: []].isEmpty)
        XCTAssertTrue(state.messagesBySession["s", default: []]
            .transcriptEntries(with: [], modelChanges: state.modelChangesBySession["s", default: []])
            .isEmpty)
    }

    func testHistoricalPermissionSetupSuccessDoesNotCreateTranscriptCommand() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()

        reducer.reduce(commandResultEvent(kind: "success", text: "preset workspace-write", sequence: 1), into: &state)

        XCTAssertTrue(state.commandResultsBySession["s", default: []].isEmpty)
    }

    func testHistoricalPermissionSetupFailureRemainsVisible() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()

        reducer.reduce(commandResultEvent(kind: "error", text: "preset workspace-write", sequence: 1), into: &state)

        let result = try! XCTUnwrap(state.commandResultsBySession["s"]?.first)
        XCTAssertEqual(result.kind, "error")
        XCTAssertEqual(result.text, "preset workspace-write")
    }

    func testReplayedModelChangeWithSameIdentityDoesNotEraseNewDraft() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()

        reducer.reduce(modelChangeEvent(model: "first", sequence: 2), into: &state)
        reducer.reduce(userMessageEvent(id: "question", text: "send this", sequence: 3), into: &state)
        reducer.reduce(modelChangeEvent(model: "next", sequence: 4), into: &state)
        reducer.reduce(sessionSnapshotEvent(sequence: 1), into: &state)
        reducer.reduce(modelChangeEvent(model: "first", sequence: 2), into: &state)

        let notices = state.modelChangesBySession["s"] ?? []
        XCTAssertEqual(notices.map(\.current.model), ["first", "next"])
        XCTAssertEqual(notices.map(\.sequence), [2, 4])
    }

    func testHistoryReplayModelChangeMergesWithCarryWithoutDuplicate() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()

        reducer.reduce(modelChangeEvent(model: "first", sequence: 1), into: &state)
        reducer.reduce(userMessageEvent(id: "question", text: "send this", sequence: 2), into: &state)
        reducer.reduce(modelChangeEvent(model: "next", sequence: 3), into: &state)
        reducer.reduce(historyEvent(type: "history.started", sequence: 4), into: &state)
        // History envelopes are newly sequenced. Its payload nevertheless
        // represents the first, already rendered model change.
        reducer.reduce(modelChangeEvent(model: "first", sequence: 5), into: &state)
        reducer.reduce(historyEvent(type: "history.completed", sequence: 6), into: &state)

        let notices = state.modelChangesBySession["s"] ?? []
        XCTAssertEqual(notices.map(\.current.model), ["first", "next"])
        XCTAssertEqual(notices.map(\.sequence), [1, 3])
    }

    func testTranscriptInterleavesMessagesAndToolCallsByArrival() {
        // A message, then a call, then another message — the shape of a real
        // turn. Rendering messages and tools as two runs put the call last.
        let messages = [
            DSHChatMessage(id: "m1", role: .assistant, markdown: "reading", sequence: 2),
            DSHChatMessage(id: "m2", role: .assistant, markdown: "done", sequence: 4),
        ]
        let tools = [
            DSHToolActivity(id: "bash-1", name: "bash", status: "succeeded", detail: "ok", sequence: 3),
        ]

        let entries = messages.transcriptEntries(with: tools)

        XCTAssertEqual(entries.map(\.id), ["turn-m1", "tool-bash-1", "turn-m2"])
    }

    func testMissingSequencesFallBackToArrivalOrderInsteadOfIDOrder() {
        // State persisted before sequences existed carries none at all. Any
        // arbitrary tie-break (id order, say) would scramble the transcript, so
        // ties must keep the order the arrays already hold.
        let messages = [
            DSHChatMessage(id: "zzz", role: .user, markdown: "first"),
            DSHChatMessage(id: "aaa", role: .assistant, markdown: "second"),
        ]

        let entries = messages.transcriptEntries(with: [])

        XCTAssertEqual(entries.map(\.id), ["turn-zzz", "turn-aaa"])
    }

    func testToolCallWithoutASequenceStillLandsAfterEarlierMessages() {
        let messages = [DSHChatMessage(id: "m1", role: .assistant, markdown: "x", sequence: 5)]
        let tools = [DSHToolActivity(id: "t1", name: "bash")]

        let entries = messages.transcriptEntries(with: tools)

        // 0 < 5, so the unsequenced call sorts before the sequenced message.
        XCTAssertEqual(entries.map(\.id), ["tool-t1", "turn-m1"])
    }

    func testCommandResultIsStampedAndInterleavedInsteadOfPinnedToBottom() {
        var state = DSHStoreState()
        let command = DSHEvent(envelope: DSHEnvelope(
            messageId: "command-event", deviceId: "d", machineId: "m", sessionId: "s", sequence: 2,
            type: "command.result",
            payload: .object([
                "sessionId": .string("s"),
                "requestId": .string("command-1"),
                "matched": .bool(true),
                "text": .string("done"),
            ])
        ))
        DSHEventReducer().reduce(command, into: &state)

        let result = try! XCTUnwrap(state.commandResultsBySession["s"]?.first)
        XCTAssertEqual(result.sequence, 2)

        let messages = [
            DSHChatMessage(id: "before", role: .user, markdown: "before", sequence: 1),
            DSHChatMessage(id: "after", role: .assistant, markdown: "after", sequence: 3),
        ]
        let entries = messages.transcriptEntries(with: [], commandResults: [result])

        XCTAssertEqual(entries.map(\.id), ["turn-before", "command-command-1", "turn-after"])
    }

    // MARK: - History replay brackets

    private func historyEvent(type: String, sessionId: String = "s",
                              sequence: Int64, batchId: String = "b1") -> DSHEvent {
        DSHEvent(envelope: DSHEnvelope(
            messageId: "evt-\(sequence)", deviceId: "d", machineId: "m",
            sessionId: sessionId, sequence: sequence, type: type,
            payload: .object([
                "sessionId": .string(sessionId),
                "batchId": .string(batchId),
            ])
        ))
    }

    private func userMessageEvent(id: String, text: String, sequence: Int64,
                                  sessionId: String = "s") -> DSHEvent {
        DSHEvent(envelope: DSHEnvelope(
            messageId: "evt-\(sequence)", deviceId: "d", machineId: "m",
            sessionId: sessionId, sequence: sequence, type: "user.message.accepted",
            payload: .object([
                "id": .string(id),
                "role": .string("user"),
                "markdown": .string(text),
            ])
        ))
    }

    private func modelChangeEvent(model: String, sequence: Int64,
                                  sessionId: String = "s") -> DSHEvent {
        DSHEvent(envelope: DSHEnvelope(
            messageId: "model-\(sequence)", deviceId: "d", machineId: "m",
            sessionId: sessionId, sequence: sequence, type: "session.model.changed",
            payload: .object([
                "sessionId": .string(sessionId),
                "current": .object([
                    "provider": .string("provider"),
                    "model": .string(model),
                ]),
            ])
        ))
    }

    private func commandResultEvent(kind: String, text: String, sequence: Int64,
                                    sessionId: String = "s") -> DSHEvent {
        DSHEvent(envelope: DSHEnvelope(
            messageId: "command-\(sequence)", deviceId: "d", machineId: "m",
            sessionId: sessionId, sequence: sequence, type: "command.result",
            payload: .object([
                "sessionId": .string(sessionId),
                "requestId": .string("request-\(sequence)"),
                "matched": .bool(true),
                "kind": .string(kind),
                "text": .string(text),
            ])
        ))
    }

    private func sessionSnapshotEvent(sequence: Int64) -> DSHEvent {
        DSHEvent(envelope: DSHEnvelope(
            messageId: "snapshot-\(sequence)", deviceId: "d", machineId: "m",
            sequence: sequence, type: "session.snapshot", payload: .array([])
        ))
    }

    private func toolStartedEvent(id: String, sequence: Int64,
                                  sessionId: String = "s") -> DSHEvent {
        DSHEvent(envelope: DSHEnvelope(
            messageId: "evt-\(sequence)", deviceId: "d", machineId: "m",
            sessionId: sessionId, sequence: sequence, type: "tool.started",
            payload: .object([
                "id": .string(id),
                "name": .string("bash"),
                "status": .string("running"),
            ])
        ))
    }

    func testHistoryReplayMergesWithoutClearing() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        // Live rows seen before the replay: unpersisted output.
        reducer.reduce(userMessageEvent(id: "live-q", text: "live?", sequence: 1), into: &state)
        reducer.reduce(toolStartedEvent(id: "live-t", sequence: 2), into: &state)
        XCTAssertEqual(state.messagesBySession["s"]?.map(\.id), ["live-q"])

        // The replay must NOT blank the arrays: replayed rows merge by id
        // (dupes are no-ops), so the screen never flashes empty mid-replay.
        reducer.reduce(historyEvent(type: "history.started", sequence: 3), into: &state)
        XCTAssertEqual(state.messagesBySession["s"]?.map(\.id), ["live-q"])
        XCTAssertEqual(state.historyCarryOverBySession["s"]?.batchId, "b1")
        XCTAssertEqual(state.historyCarryOverBySession["s"]?.messages.map(\.id), ["live-q"])
        XCTAssertEqual(state.historyCarryOverBySession["s"]?.tools.map(\.id), ["live-t"])

        reducer.reduce(userMessageEvent(id: "h-q", text: "old?", sequence: 4), into: &state)
        reducer.reduce(toolStartedEvent(id: "h-t", sequence: 5), into: &state)
        reducer.reduce(historyEvent(type: "history.completed", sequence: 6), into: &state)

        // Live rows keep their place; replayed rows append; carry (already
        // present) merges as a no-op. Render order comes from the sequence
        // sort, not array order.
        XCTAssertEqual(state.messagesBySession["s"]?.map(\.id), ["live-q", "h-q"])
        XCTAssertEqual(state.toolsBySession["s"]?.map(\.id), ["live-t", "h-t"])
        XCTAssertNil(state.historyCarryOverBySession["s"])
        // The replay must not renumber the live rows.
        XCTAssertEqual(state.messagesBySession["s"]?.first?.sequence, 1)
    }

    func testHistoryCompletionWithStaleBatchIdIsIgnored() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        reducer.reduce(historyEvent(type: "history.started", sequence: 1, batchId: "b1"),
                       into: &state)
        // A completion from an overlapping older batch must not merge.
        reducer.reduce(historyEvent(type: "history.completed", sequence: 2, batchId: "b0"),
                       into: &state)
        XCTAssertNotNil(state.historyCarryOverBySession["s"])
    }

    func testHistoryForceMergeIgnoresBatchId() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        reducer.reduce(userMessageEvent(id: "live-q", text: "live?", sequence: 1), into: &state)
        reducer.reduce(historyEvent(type: "history.started", sequence: 2, batchId: "b1"), into: &state)
        reducer.reduce(userMessageEvent(id: "h-q", text: "old?", sequence: 3), into: &state)
        // Timeout path: merge whatever is open (carry rows already present
        // merge as no-ops).
        reducer.completeHistory(sessionId: "s", batchId: nil, into: &state)
        XCTAssertEqual(state.messagesBySession["s"]?.map(\.id), ["live-q", "h-q"])
        XCTAssertNil(state.historyCarryOverBySession["s"])
    }

    func testOverlappingReplaysDoNotLoseRows() {
        // A second open while the first replay still streams must fold into
        // the open carry, not replace it: replacing discards rows outside
        // the replay window, and the first completion then drops them for
        // good (transcript goes blank except for freshly streamed rows).
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        reducer.reduce(userMessageEvent(id: "old", text: "old?", sequence: 1), into: &state)
        reducer.reduce(historyEvent(type: "history.started", sequence: 2, batchId: "b1"), into: &state)
        reducer.reduce(userMessageEvent(id: "r1", text: "replayed?", sequence: 3), into: &state)
        reducer.reduce(historyEvent(type: "history.started", sequence: 4, batchId: "b2"), into: &state)
        reducer.reduce(userMessageEvent(id: "r2", text: "replayed?", sequence: 5), into: &state)
        reducer.reduce(historyEvent(type: "history.completed", sequence: 6, batchId: "b1"), into: &state)
        reducer.reduce(historyEvent(type: "history.completed", sequence: 7, batchId: "b2"), into: &state)
        // Render order comes from the sequence sort, so compare as a set.
        XCTAssertEqual(state.messagesBySession["s"]?.map(\.id).sorted(), ["old", "r1", "r2"])
        XCTAssertNil(state.historyCarryOverBySession["s"])
    }

    func testAttachmentCacheEvictsOldestFirst() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, bytes: Int, age: TimeInterval) throws {
            let url = dir.appendingPathComponent(name)
            try Data(repeating: 0x41, count: bytes).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)],
                ofItemAtPath: url.path)
        }
        try write("old.bin", bytes: 100, age: 100)
        try write("new.bin", bytes: 100, age: 0)
        DSHAppModel.evictAttachmentCache(directory: dir, keepingBytesUnder: 150)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("old.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("new.bin").path))
        // Under budget: nothing is touched.
        DSHAppModel.evictAttachmentCache(directory: dir, keepingBytesUnder: 10_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("new.bin").path))
    }

    @MainActor
    func testQueuedPromptHoldEditCancelTake() {
        // Unique session id: the queue persists to UserDefaults per machine,
        // so a fixed id would leak entries across test runs.
        let sid = "q-\(UUID().uuidString)"
        let model = DSHAppModel(transport: DSHPreviewTransport(), initialState: DSHStoreState(), isPaired: true)
        model.holdQueuedPrompt(text: "  first  ", for: sid)
        model.holdQueuedPrompt(text: "second", for: sid)
        XCTAssertEqual(model.queuedPrompts(for: sid).map(\.text), ["first", "second"])
        let first = model.queuedPrompts(for: sid)[0]
        XCTAssertFalse(first.sent)
        model.updateQueuedPrompt(id: first.id, text: "first-edited", sessionID: sid)
        XCTAssertEqual(model.queuedPrompts(for: sid).first?.text, "first-edited")
        XCTAssertTrue(model.cancelQueuedPrompt(id: first.id, sessionID: sid))
        XCTAssertEqual(model.queuedPrompts(for: sid).map(\.text), ["second"])
        // Server-sent mirrors refuse local cancel; acceptance still retires.
        model.noteQueuedPrompt(text: "server", mode: "queue", for: sid)
        let server = model.queuedPrompts(for: sid).first(where: { $0.text == "server" })!
        XCTAssertTrue(server.sent)
        XCTAssertFalse(model.cancelQueuedPrompt(id: server.id, sessionID: sid))
        model.matchQueuedPrompt(text: "server", sessionID: sid)
        let second = model.queuedPrompts(for: sid).first(where: { $0.text == "second" })!
        XCTAssertEqual(model.takeQueuedPrompt(id: second.id, sessionID: sid)?.text, "second")
        XCTAssertTrue(model.queuedPrompts(for: sid).isEmpty)
    }

    @MainActor
    func testPendingSendMatchParkAndRetry() {
        let sid = "send-\(UUID().uuidString)"
        let model = DSHAppModel(transport: DSHPreviewTransport(), initialState: DSHStoreState(), isPaired: true)
        // Sending records a pending ack; acceptance retires it.
        model.sendPrompt("hello", to: sid)
        XCTAssertEqual(model.pendingSendCount(for: sid), 1)
        model.confirmPendingSend(text: "hello", sessionID: sid)
        XCTAssertEqual(model.pendingSendCount(for: sid), 0)
        XCTAssertNil(model.failedSend)
        // A transport throw parks the prompt with its text for retry.
        let command = DSHCommand(
            requestId: "req-1", deviceId: "d", machineId: "m", sessionId: sid,
            type: "prompt.send",
            payload: .object(["text": .string("retry me"),
                              "attachments": .array([])]))
        model.parkFailedPromptSend(command, error: NSError(domain: "test", code: 1))
        XCTAssertEqual(model.failedSend?.text, "retry me")
        XCTAssertEqual(model.failedSend?.sessionID, sid)
        // Retry clears the banner and re-records a fresh pending send.
        model.retryFailedSend()
        XCTAssertNil(model.failedSend)
        XCTAssertEqual(model.pendingSendCount(for: sid), 1)
        model.dismissFailedSend()
    }

    @MainActor
    func testPureAttachmentAcceptanceUsesRequestIdWhenMessageHasNoText() {
        let sid = "attachment-send-\(UUID().uuidString)"
        let requestID = "attachment-request-\(UUID().uuidString)"
        let model = DSHAppModel(transport: DSHPreviewTransport(), initialState: DSHStoreState(), isPaired: true)
        model.sendPrompt("", attachments: ["receipt-1"], to: sid, requestId: requestID)
        XCTAssertEqual(model.pendingSendCount(for: sid), 1)

        // The accepted user message can contain only a file, so its markdown
        // is empty. The Bridge correlates the envelope message id to the
        // original prompt request and must still clear the pending bubble.
        model.confirmPendingSend(text: "", sessionID: sid, requestID: requestID)
        XCTAssertEqual(model.pendingSendCount(for: sid), 0)
        XCTAssertNil(model.failedSend)

        let lateRequestID = "late-attachment-request-\(UUID().uuidString)"
        model.sendPrompt("", attachments: ["receipt-2"], to: sid, requestId: lateRequestID)
        model.timeoutPendingSend(requestId: lateRequestID)
        XCTAssertNotNil(model.failedSend)
        model.confirmPendingSend(text: "", sessionID: sid, requestID: lateRequestID)
        XCTAssertNil(model.failedSend)
    }

    func testToolsFoldIntoPrecedingAssistantTurn() {
        let entries: [DSHTranscriptEntry] = [
            .turn(DSHTranscriptBlock(id: "q", messages: [
                DSHChatMessage(id: "q", role: .user, markdown: "q?", sequence: 1),
            ])),
            .turn(DSHTranscriptBlock(id: "a1", messages: [
                DSHChatMessage(id: "a1", role: .assistant, markdown: "ans", sequence: 2),
            ])),
            .tool(DSHToolActivity(id: "t", name: "bash", status: "succeeded", sequence: 3)),
        ]
        let sections = entries.groupedTurns()
        XCTAssertEqual(sections.count, 2)
        guard case .turn(let block, let tools) = sections[1] else {
            return XCTFail("Assistant turn should carry its tools")
        }
        XCTAssertEqual(block.id, "a1")
        XCTAssertEqual(tools.map(\.id), ["t"])
    }

    func testOrphanToolWithoutAssistantTurnStaysStandalone() {
        let entries: [DSHTranscriptEntry] = [
            .tool(DSHToolActivity(id: "t", name: "bash", status: "running", sequence: 1)),
            .turn(DSHTranscriptBlock(id: "q", messages: [
                DSHChatMessage(id: "q", role: .user, markdown: "q?", sequence: 2),
            ])),
        ]
        let sections = entries.groupedTurns()
        XCTAssertEqual(sections.count, 2)
        guard case .row(let entry) = sections[0] else {
            return XCTFail("Orphan tool should stand alone")
        }
        XCTAssertEqual(entry.id, "tool-t")
    }

    func testReasoningOnlyTurnsFoldIntoFollowingAnswer() {
        // One agentic turn arrives as think → tool → think → tool → answer.
        // Rendering one "思考" row per think step buries the conversation;
        // they must fold into a single timeline row with the final answer.
        let entries: [DSHTranscriptEntry] = [
            .turn(DSHTranscriptBlock(id: "r1", messages: [
                DSHChatMessage(id: "r1", role: .assistant, markdown: "",
                               reasoning: "first thought", sequence: 1),
            ])),
            .tool(DSHToolActivity(id: "t1", name: "bash", status: "succeeded", sequence: 2)),
            .turn(DSHTranscriptBlock(id: "r2", messages: [
                DSHChatMessage(id: "r2", role: .assistant, markdown: "",
                               reasoning: "second thought", sequence: 3),
            ])),
            .tool(DSHToolActivity(id: "t2", name: "bash", status: "succeeded", sequence: 4)),
            .turn(DSHTranscriptBlock(id: "a", messages: [
                DSHChatMessage(id: "a", role: .assistant, markdown: "done", sequence: 5),
            ])),
        ]
        let sections = entries.groupedTurns()
        XCTAssertEqual(sections.count, 1)
        guard case .turn(let block, let tools) = sections[0] else {
            return XCTFail("Think steps should fold into the answer turn")
        }
        XCTAssertEqual(block.messages.map(\.id), ["r1", "r2", "a"])
        XCTAssertEqual(block.visibleMessages.map(\.id), ["a"])
        XCTAssertTrue(block.reasoning.contains("first thought"))
        XCTAssertTrue(block.reasoning.contains("second thought"))
        XCTAssertEqual(tools.map(\.id), ["t1", "t2"])
    }

    func testInterruptionsDoNotSplitReasoningFold() {
        // think → user message → /command card → answer must render ONE
        // timeline row: interruptions render in place, the pending think
        // attaches to the next visible assistant turn instead of stranding
        // a lone "思考" row above the duration row.
        let entries: [DSHTranscriptEntry] = [
            .turn(DSHTranscriptBlock(id: "r", messages: [
                DSHChatMessage(id: "r", role: .assistant, markdown: "",
                               reasoning: "thinking…", sequence: 1),
            ])),
            .turn(DSHTranscriptBlock(id: "u", messages: [
                DSHChatMessage(id: "u", role: .user, markdown: "and?", sequence: 2),
            ])),
            .command(DSHCommandResult(sessionId: "s", requestId: "c1", matched: true,
                                      kind: "goal", text: "goal set", sequence: 3)),
            .turn(DSHTranscriptBlock(id: "a", messages: [
                DSHChatMessage(id: "a", role: .assistant, markdown: "done", sequence: 4),
            ])),
        ]
        let sections = entries.groupedTurns()
        XCTAssertEqual(sections.count, 3)
        guard case .turn(let block, _) = sections[2] else {
            return XCTFail("Think step should fold into the answer turn")
        }
        XCTAssertEqual(block.messages.map(\.id), ["r", "a"])
        XCTAssertEqual(block.visibleMessages.map(\.id), ["a"])
    }

    func testTrailingReasoningOnlyTurnStaysStandalone() {
        // Live streaming: reasoning arrived but the answer text has not yet.
        // It must stay visible (with its running tools) rather than vanish.
        let entries: [DSHTranscriptEntry] = [
            .turn(DSHTranscriptBlock(id: "a", messages: [
                DSHChatMessage(id: "a", role: .assistant, markdown: "done", sequence: 1),
            ])),
            .turn(DSHTranscriptBlock(id: "r", messages: [
                DSHChatMessage(id: "r", role: .assistant, markdown: "",
                               reasoning: "thinking…", sequence: 2),
            ])),
            .tool(DSHToolActivity(id: "t", name: "bash", status: "running", sequence: 3)),
        ]
        let sections = entries.groupedTurns()
        XCTAssertEqual(sections.count, 2)
        guard case .turn(let block, let tools) = sections[1] else {
            return XCTFail("Live think step should stay its own section")
        }
        XCTAssertEqual(block.messages.map(\.id), ["r"])
        XCTAssertEqual(tools.map(\.id), ["t"])
    }

    func testModelChangeDoesNotSplitReasoningFold() {
        // think → model notice → answer must render one timeline row, not a
        // stranded "思考" row above the duration row.
        let notice = DSHModelChangeNotice(
            sessionId: "s",
            current: DSHModelSelection(provider: "p", model: "m"),
            sequence: 2, timestamp: 2)
        let entries: [DSHTranscriptEntry] = [
            .turn(DSHTranscriptBlock(id: "r", messages: [
                DSHChatMessage(id: "r", role: .assistant, markdown: "",
                               reasoning: "thinking…", sequence: 1),
            ])),
            .modelChange(notice),
            .turn(DSHTranscriptBlock(id: "a", messages: [
                DSHChatMessage(id: "a", role: .assistant, markdown: "done", sequence: 3),
            ])),
        ]
        let sections = entries.groupedTurns()
        XCTAssertEqual(sections.count, 2)
        guard case .turn(let block, _) = sections[1] else {
            return XCTFail("Think step should fold into the answer turn")
        }
        XCTAssertEqual(block.messages.map(\.id), ["r", "a"])
        XCTAssertEqual(block.visibleMessages.map(\.id), ["a"])
    }

    func testReplayedRowsKeepFirstSequenceInsteadOfRenumbering() {        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        // Live rows first.
        reducer.reduce(userMessageEvent(id: "q", text: "q?", sequence: 1), into: &state)
        reducer.reduce(toolStartedEvent(id: "t", sequence: 2), into: &state)
        // The same rows replayed later (re-open, refresh, backfill) update
        // content in place but must not move ahead of live rows that
        // followed the first sighting.
        reducer.reduce(userMessageEvent(id: "q", text: "q?", sequence: 10), into: &state)
        reducer.reduce(toolStartedEvent(id: "t", sequence: 11), into: &state)

        XCTAssertEqual(state.messagesBySession["s"]?.first?.sequence, 1)
        XCTAssertEqual(state.toolsBySession["s"]?.first?.sequence, 2)

        let messages = state.messagesBySession["s"] ?? []
        let tools = state.toolsBySession["s"] ?? []
        let entries = messages.transcriptEntries(with: tools)
        XCTAssertEqual(entries.map(\.id), ["turn-q", "tool-t"])
    }

    func testMessageTimestampIsStampedOnceAndSurvivesReplay() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        func accepted(sequence: Int64, timestamp: Int64) -> DSHEvent {
            DSHEvent(envelope: DSHEnvelope(
                messageId: "evt-\(sequence)", deviceId: "d", machineId: "m",
                sessionId: "s", sequence: sequence, timestamp: timestamp,
                type: "user.message.accepted",
                payload: .object([
                    "id": .string("q"),
                    "role": .string("user"),
                    "markdown": .string("q?"),
                ])
            ))
        }
        reducer.reduce(accepted(sequence: 1, timestamp: 1_000), into: &state)
        reducer.reduce(accepted(sequence: 10, timestamp: 2_000), into: &state)
        XCTAssertEqual(state.messagesBySession["s"]?.first?.timestamp, 1_000)
    }

    @MainActor
    func testSessionDotPrioritizesErrorOverApprovalOverActivity() {
        var state = DSHStoreState()
        let quiet = DSHSessionSummary(id: "quiet", title: "q", updatedAt: 0)
        let failed = DSHSessionSummary(id: "failed", title: "f", updatedAt: 0)
        let waiting = DSHSessionSummary(id: "waiting", title: "w", updatedAt: 0)
        let active = DSHSessionSummary(id: "active", title: "a", updatedAt: 0, running: true)
        state.sessions = [quiet, failed, waiting, active]
        state.turnStateBySession["failed"] = "failed"
        state.pendingApprovals = [
            DSHApprovalRequest(id: "ap", sessionId: "waiting", toolName: "bash", reason: "run?"),
        ]
        let model = DSHAppModel(transport: DSHPreviewTransport(), initialState: state, isPaired: true)
        XCTAssertEqual(model.sessionDot(for: quiet), .none)
        XCTAssertEqual(model.sessionDot(for: failed), .red)
        XCTAssertEqual(model.sessionDot(for: waiting), .yellow)
        XCTAssertEqual(model.sessionDot(for: active), .green)
    }

    @MainActor
    func testLocalTransportFailureClearsWorkspaceAndDirectoryLoading() async {
        let transport = CorrelationTransport(failingTypes: ["workspace.create", "directory.list"])
        let model = DSHAppModel(transport: transport, initialState: .init(), isPaired: true)

        model.createWorkspace(at: "/Users/me/Project")
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(model.isCreatingWorkspace)

        model.listDirectory(at: "/Users/me")
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(model.isLoadingDirectory)
    }

    @MainActor
    func testWorkspaceCreationDismissesOnlyForMatchingRemoteAcknowledgement() async throws {
        let transport = CorrelationTransport()
        let model = DSHAppModel(transport: transport, initialState: .init(), isPaired: true)
        model.connect()
        model.createWorkspace(at: "/Users/me/Existing")
        try? await Task.sleep(for: .milliseconds(80))
        let pendingCommand = await transport.lastCommand(ofType: "workspace.create")
        let requestID = try XCTUnwrap(pendingCommand?.requestId)

        await transport.emit(event(type: "workspace.created", messageID: "another-device", sequence: 1,
                                   payload: .object([
                                    "id": .string("existing"), "path": .string("/Users/me/Existing"),
                                    "title": .string("Existing"),
                                   ])))
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(model.isCreatingWorkspace)
        XCTAssertNil(model.createdWorkspace)

        await transport.emit(event(type: "workspace.created", messageID: requestID, sequence: 2,
                                   payload: .object([
                                    "id": .string("existing"), "path": .string("/Users/me/Existing"),
                                    "title": .string("Existing"),
                                   ])))
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(model.isCreatingWorkspace)
        XCTAssertEqual(model.createdWorkspace?.id, "existing")
        XCTAssertEqual(model.createdWorkspace?.name, "Existing")
        model.disconnect()
    }

    @MainActor
    func testOnlyLatestDirectoryReplyUpdatesFolderBrowser() async throws {
        let transport = CorrelationTransport()
        let model = DSHAppModel(transport: transport, initialState: .init(), isPaired: true)
        model.connect()
        model.listDirectory(at: "/Users/me")
        try? await Task.sleep(for: .milliseconds(50))
        let firstCommand = await transport.lastCommand(ofType: "directory.list")
        let firstID = try XCTUnwrap(firstCommand?.requestId)
        model.listDirectory(at: "/Users/me/New")
        try? await Task.sleep(for: .milliseconds(50))
        let secondCommand = await transport.lastCommand(ofType: "directory.list")
        let secondID = try XCTUnwrap(secondCommand?.requestId)
        XCTAssertNotEqual(firstID, secondID)

        await transport.emit(event(type: "directory.list", messageID: firstID, sequence: 1,
                                   payload: directoryPayload(path: "/Users/me", directory: "Old")))
        await transport.emit(event(type: "directory.list", messageID: secondID, sequence: 2,
                                   payload: directoryPayload(path: "/Users/me/New", directory: "Current")))
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.directoryListing?.path, "/Users/me/New")
        XCTAssertEqual(model.directoryListing?.directories.map(\.name), ["Current"])
        XCTAssertFalse(model.isLoadingDirectory)
        model.disconnect()
    }

    @MainActor
    func testTranscriptCacheRefreshesForLiveDeltaAndLocalHide() async {
        UserDefaults.standard.removeObject(forKey: DSHAppModel.hiddenMessagesKey)
        defer { UserDefaults.standard.removeObject(forKey: DSHAppModel.hiddenMessagesKey) }

        var state = DSHStoreState()
        state.messagesBySession["s"] = [
            DSHChatMessage(id: "question", role: .user, markdown: "Hello", sequence: 1),
        ]
        let transport = CorrelationTransport()
        let model = DSHAppModel(transport: transport, initialState: state, isPaired: true)

        // Prime both caches before the live event arrives.
        XCTAssertEqual(model.transcriptEntries(for: "s").map(\.id), ["turn-question"])
        XCTAssertEqual(model.transcriptSections(for: "s").map(\.id), ["section-turn-question"])

        model.connect()
        try? await Task.sleep(for: .milliseconds(30))
        await transport.emit(DSHEvent(envelope: DSHEnvelope(
            messageId: "delta", deviceId: "device", machineId: "machine", sessionId: "s",
            sequence: 2, type: "assistant.message.delta",
            payload: .object(["messageId": .string("partial"), "text": .string("Live")])
        )))
        try? await Task.sleep(for: .milliseconds(90))

        XCTAssertEqual(model.transcriptEntries(for: "s").map(\.id), ["turn-question", "turn-partial"])
        model.hideMessage("partial", in: "s")
        XCTAssertEqual(model.transcriptEntries(for: "s").map(\.id), ["turn-question"])
        model.disconnect()
    }

    private func directoryPayload(path: String, directory: String) -> DSHJSONValue {
        .object([
            "path": .string(path),
            "directories": .array([
                .object(["name": .string(directory), "path": .string("\(path)/\(directory)")]),
            ]),
        ])
    }

    private func event(type: String, messageID: String, sequence: Int64,
                       payload: DSHJSONValue) -> DSHEvent {
        DSHEvent(envelope: DSHEnvelope(messageId: messageID, deviceId: "device", machineId: "machine",
                                        sequence: sequence, type: type, payload: payload))
    }
}

private actor CorrelationTransport: DSHAppTransport {
    private var continuation: AsyncThrowingStream<DSHEvent, Error>.Continuation?
    private var commands: [DSHCommand] = []
    private let failingTypes: Set<String>

    init(failingTypes: Set<String> = []) { self.failingTypes = failingTypes }

    func pair(serverAddress: String, machineId: String, credential: DSHPairingCredential,
              deviceName: String) async throws -> DSHRemoteProfile {
        DSHRemoteProfile(relayBaseURL: URL(string: "https://example.test")!,
                         deviceId: "device", machineId: "machine", machineName: "Mac")
    }

    func connect() async -> AsyncThrowingStream<DSHEvent, Error> {
        let stream = AsyncThrowingStream<DSHEvent, Error>.makeStream()
        continuation = stream.continuation
        return stream.stream
    }

    func send(_ command: DSHCommand) async throws {
        commands.append(command)
        if failingTypes.contains(command.type) {
            throw DSHWebSocketError.notConnected
        }
    }

    func disconnect() async { continuation?.finish(); continuation = nil }
    func forgetPairing() async throws { await disconnect() }
    func setActiveMachine(_ machineId: String) async {}
    func removeMachine(_ machineId: String) async throws {}
    func pairedDevices() async throws -> [DSHRelayDevice] { [] }
    func revokeDevice(_ deviceId: String) async throws {}

    func lastCommand(ofType type: String) -> DSHCommand? {
        commands.last(where: { $0.type == type })
    }

    func emit(_ event: DSHEvent) { continuation?.yield(event) }
}

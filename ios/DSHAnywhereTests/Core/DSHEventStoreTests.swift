import XCTest
@testable import DSHAnywhere

final class DSHEventStoreTests: XCTestCase {
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

    func testAuthoritativeSnapshotStartsANewSequenceEpochAfterConnectorRestart() {
        var state = DSHStoreState()
        state.lastSequence = 42
        state.sessions = [DSHSessionSummary(id: "stale", title: "Stale", updatedAt: 1)]
        let snapshot = DSHEvent(envelope: DSHEnvelope(
            messageId: "snapshot", deviceId: "d", machineId: "m", sequence: 1,
            type: "session.snapshot", payload: .array([
                .object(["id": .string("current"), "title": .string("Current"), "updatedAt": .number(2)]),
            ])
        ))
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

    func testSessionsOutsideEveryWorkspaceShareOneBucket() {
        let sessions = [
            DSHSessionSummary(id: "a", title: "Real work", updatedAt: 30, workspaceName: "project-a"),
            DSHSessionSummary(id: "b", title: "Loose one", updatedAt: 20, cwd: "/tmp/one"),
            DSHSessionSummary(id: "c", title: "Loose two", updatedAt: 10, cwd: "/tmp/two"),
        ]

        let groups = sessions.groupedForList(.byWorkspace, showArchived: false)

        // Two directories with no workspace must not become two workspaces.
        XCTAssertEqual(groups.map(\.title), ["project-a", "Other"])
        XCTAssertEqual(groups[1].sessions.map(\.id), ["b", "c"])
        XCTAssertTrue(groups[1].isUnfiled)
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
}

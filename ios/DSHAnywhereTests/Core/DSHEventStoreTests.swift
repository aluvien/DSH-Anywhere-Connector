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
}

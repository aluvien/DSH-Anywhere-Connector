import XCTest
@testable import DSHAnywhere

final class DSHWebSocketConnectionTests: XCTestCase {
    func testBackoffIsExponentialAndCapped() {
        let backoff = DSHExponentialBackoff(initialNanoseconds: 10, maximumNanoseconds: 25)
        XCTAssertEqual(backoff.delayNanoseconds(for: 1), 10)
        XCTAssertEqual(backoff.delayNanoseconds(for: 2), 20)
        XCTAssertEqual(backoff.delayNanoseconds(for: 3), 25)
        XCTAssertEqual(backoff.delayNanoseconds(for: 0), 0)

        let productionBackoff = DSHExponentialBackoff()
        for attempt in [7, 36, 37, 100, 1_000] {
            XCTAssertEqual(productionBackoff.delayNanoseconds(for: attempt), 30_000_000_000,
                           "attempt \(attempt) must remain capped without trapping")
        }
        XCTAssertEqual(DSHExponentialBackoff(initialNanoseconds: 100, maximumNanoseconds: 10)
            .delayNanoseconds(for: 1), 10)
        XCTAssertEqual(DSHExponentialBackoff(initialNanoseconds: 10, maximumNanoseconds: 100,
                                             multiplier: .nan)
            .delayNanoseconds(for: 100), 10)
        XCTAssertEqual(DSHExponentialBackoff(initialNanoseconds: UInt64.max,
                                             maximumNanoseconds: UInt64.max)
            .delayNanoseconds(for: 2), UInt64.max)
    }

    func testHandshakeAuthenticationFailureStopsReconnect() async throws {
        let fake = RecordingWebSocketTask()
        fake.responseStatusCode = 401
        fake.receiveError = URLError(.badServerResponse)
        XCTAssertEqual((fake as any DSHWebSocketTasking).responseStatusCode, 401)
        let config = DSHWebSocketConfiguration(url: URL(string: "wss://example.test/socket")!,
                                                bearerToken: "expired", deviceId: "device", machineId: "machine",
                                                backoff: .init(initialNanoseconds: 1, maximumNanoseconds: 1))
        let connection = DSHWebSocketConnection(configuration: config, taskFactory: { _ in fake })
        _ = await connection.connect()
        let state = try await waitForFailure(connection)
        if case .failed(let message) = state {
            XCTAssertTrue(message.contains("credentials"))
        } else {
            XCTFail("authentication failure must stop reconnecting (state: \(state))")
        }
        XCTAssertEqual(fake.resumeCount, 1)
        await connection.disconnect()
    }

    func testRevokedRelayCloseStopsReconnect() async throws {
        let fake = RecordingWebSocketTask()
        fake.closeCodeRawValue = 4401
        fake.receiveError = DSHWebSocketError.closed
        XCTAssertEqual((fake as any DSHWebSocketTasking).closeCodeRawValue, 4401)
        let config = DSHWebSocketConfiguration(url: URL(string: "wss://example.test/socket")!,
                                                bearerToken: "revoked", deviceId: "device", machineId: "machine",
                                                backoff: .init(initialNanoseconds: 1, maximumNanoseconds: 1))
        let connection = DSHWebSocketConnection(configuration: config, taskFactory: { _ in fake })
        _ = await connection.connect()
        let state = try await waitForFailure(connection)
        if case .failed(let message) = state {
            XCTAssertTrue(message.contains("credentials"))
        } else {
            XCTFail("revoked credentials must stop reconnecting (state: \(state))")
        }
        XCTAssertEqual(fake.resumeCount, 1)
        await connection.disconnect()
    }

    func testDroppedEventDoesNotAdvanceResumeCursorPastTheGap() async throws {
        let fake = RecordingWebSocketTask()
        let config = DSHWebSocketConfiguration(url: URL(string: "wss://example.test/socket")!,
                                                bearerToken: "secret", deviceId: "device", machineId: "machine",
                                                backoff: .init(initialNanoseconds: 1, maximumNanoseconds: 1),
                                                maximumReconnectAttempts: 0)
        let connection = DSHWebSocketConnection(configuration: config, taskFactory: { _ in fake })
        _ = await connection.connect()
        for sequence in 1...600 {
            fake.enqueue(try relaySnapshot(messageID: "event-\(sequence)", sequence: Int64(sequence), title: "Event"))
        }
        let state = try await waitForFailure(connection)

        // The bounded stream is intentionally not consumed. Once it fills, the
        // connection fails and keeps the last accepted cursor; the next resume
        // can therefore request the dropped event instead of skipping it.
        let cursor = await connection.lastSequence
        XCTAssertLessThan(cursor, 600)
        if case .failed = state {
            // Expected terminal state with maximumReconnectAttempts = 0.
        } else {
            XCTFail("buffer overflow should stop this bounded test connection (state: \(state))")
        }
        await connection.disconnect()
    }

    func testBearerRequestAndRelayResumeAreSentAfterReady() async throws {
        let fake = RecordingWebSocketTask()
        let config = DSHWebSocketConfiguration(url: URL(string: "wss://example.test/socket")!,
                                                bearerToken: "secret", deviceId: "device", machineId: "machine",
                                                backoff: .init(initialNanoseconds: 1, maximumNanoseconds: 1),
                                                maximumReconnectAttempts: 0)
        let connection = DSHWebSocketConnection(configuration: config, lastSequence: 7,
                                                 taskFactory: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertNil(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.query)
            return fake
        })
        _ = await connection.connect()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fake.resumeCount, 1)
        let commands = await fake.sentCommands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].type, "connection.resume")
        XCTAssertEqual(commands[0].deviceId, "device")
        XCTAssertEqual(commands[0].machineId, "machine")
        XCTAssertEqual(commands[0].payload, .object(["lastSequence": .number(7),
                                                      "includeArchived": .bool(false)]))
        XCTAssertEqual(commands[1].type, "session.list")
        XCTAssertEqual(commands[1].deviceId, "device")
        XCTAssertEqual(commands[1].machineId, "machine")
        XCTAssertEqual(commands[1].payload, .object(["includeArchived": .bool(false)]))
        await connection.disconnect()
    }

    private func waitForFailure(_ connection: DSHWebSocketConnection) async throws -> DSHConnectionState {
        for _ in 0..<200 {
            let state = await connection.state
            if case .failed = state { return state }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await connection.state
    }

    func testSendWaitsForRelayHandshakeDuringReconnect() async throws {
        let fake = RecordingWebSocketTask()
        let config = DSHWebSocketConfiguration(url: URL(string: "wss://example.test/socket")!,
                                                bearerToken: "secret", deviceId: "device", machineId: "machine",
                                                backoff: .init(initialNanoseconds: 1, maximumNanoseconds: 1),
                                                maximumReconnectAttempts: 0)
        let connection = DSHWebSocketConnection(configuration: config, taskFactory: { _ in fake })
        _ = await connection.connect()
        let command = DSHCommand(version: 1, deviceId: "device", machineId: "machine",
                                  type: "model.catalog", payload: .object([:]))
        try await connection.send(command)
        let commands = await fake.sentCommands
        XCTAssertEqual(commands.map(\.type), ["connection.resume", "session.list", "model.catalog"])
        await connection.disconnect()
    }

    func testMachinePresenceIsForwardedToTheUIStream() async throws {
        let presence = DSHRelayPresenceMessage(type: "relay.presence", machineId: "machine",
                                               role: .machine, online: false,
                                               deviceId: nil, serverTime: 2)
        let fake = RecordingWebSocketTask(additionalMessages: [
            .data(try JSONEncoder().encode(presence)),
        ])
        let config = DSHWebSocketConfiguration(url: URL(string: "wss://example.test/socket")!,
                                                bearerToken: "secret", deviceId: "device", machineId: "machine",
                                                backoff: .init(initialNanoseconds: 1, maximumNanoseconds: 1),
                                                maximumReconnectAttempts: 0)
        let connection = DSHWebSocketConnection(configuration: config, taskFactory: { _ in fake })
        let stream = await connection.connect()
        var iterator = stream.makeAsyncIterator()

        var sawOfflinePresence = false
        for _ in 0..<4 {
            guard let event = try await iterator.next() else { break }
            if case .machinePresence(false) = event.kind {
                sawOfflinePresence = true
                break
            }
        }
        XCTAssertTrue(sawOfflinePresence)
        await connection.disconnect()
    }

    func testUnavailableMacKeepsTheHealthyRelaySocketOpen() async throws {
        let unavailable = DSHRelayErrorMessage(type: "relay.error", code: "target_unavailable",
                                               message: "No connected machine is available.",
                                               machineId: "machine", messageId: "resume")
        let fake = RecordingWebSocketTask(additionalMessages: [
            .data(try JSONEncoder().encode(unavailable)),
        ])
        let config = DSHWebSocketConfiguration(url: URL(string: "wss://example.test/socket")!,
                                                bearerToken: "secret", deviceId: "device", machineId: "machine",
                                                backoff: .init(initialNanoseconds: 1, maximumNanoseconds: 1),
                                                maximumReconnectAttempts: 0)
        let connection = DSHWebSocketConnection(configuration: config, taskFactory: { _ in fake })
        let stream = await connection.connect()
        var iterator = stream.makeAsyncIterator()
        var sawOffline = false
        for _ in 0..<5 {
            guard let event = try await iterator.next() else { break }
            if case .machinePresence(false) = event.kind { sawOffline = true; break }
        }

        XCTAssertTrue(sawOffline)
        let state = await connection.state
        XCTAssertEqual(state, .connected)
        XCTAssertEqual(fake.resumeCount, 1)
        await connection.disconnect()
    }

    func testOnlyLatestCorrelatedListSnapshotCanResetAConnectorEpoch() async throws {
        let fake = RecordingWebSocketTask()
        let config = DSHWebSocketConfiguration(url: URL(string: "wss://example.test/socket")!,
                                                bearerToken: "secret", deviceId: "device", machineId: "machine",
                                                backoff: .init(initialNanoseconds: 1, maximumNanoseconds: 1),
                                                maximumReconnectAttempts: 0)
        let connection = DSHWebSocketConnection(configuration: config, lastSequence: 42,
                                                taskFactory: { _ in fake })
        let stream = await connection.connect()
        var iterator = stream.makeAsyncIterator()
        let requestID = "fresh-list"
        try await connection.send(DSHCommand(requestId: requestID, deviceId: "device", machineId: "machine",
                                             type: "session.list",
                                             payload: .object(["includeArchived": .bool(true)])))

        // A replay can have a lower sequence but no current request id. It
        // must not restart the cursor or paint an obsolete home list.
        fake.enqueue(try relaySnapshot(messageID: "old-replay", sequence: 3, title: "Old"))
        fake.enqueue(try relaySnapshot(messageID: requestID, sequence: 1, title: "Fresh"))

        var receivedSnapshot: DSHEvent?
        for _ in 0..<4 {
            guard let event = try await iterator.next() else { break }
            if case .sessionSnapshot = event.kind {
                receivedSnapshot = event
                break
            }
        }
        XCTAssertEqual(receivedSnapshot?.envelope.messageId, requestID)
        XCTAssertTrue(receivedSnapshot?.establishesSequenceEpoch == true)
        let finalSequence = await connection.lastSequence
        XCTAssertEqual(finalSequence, 1)
        await connection.disconnect()
    }

    func testLateOlderListSnapshotCannotOverwriteAcceptedNewerSnapshot() async throws {
        let fake = RecordingWebSocketTask()
        let config = DSHWebSocketConfiguration(url: URL(string: "wss://example.test/socket")!,
                                                bearerToken: "secret", deviceId: "device", machineId: "machine",
                                                backoff: .init(initialNanoseconds: 1, maximumNanoseconds: 1),
                                                maximumReconnectAttempts: 0)
        let connection = DSHWebSocketConnection(configuration: config, taskFactory: { _ in fake })
        let stream = await connection.connect()
        var iterator = stream.makeAsyncIterator()
        try await connection.send(DSHCommand(requestId: "list-active", deviceId: "device", machineId: "machine",
                                             type: "session.list",
                                             payload: .object(["includeArchived": .bool(false)])))
        try await connection.send(DSHCommand(requestId: "list-archive", deviceId: "device", machineId: "machine",
                                             type: "session.list",
                                             payload: .object(["includeArchived": .bool(true)])))

        // The newer response wins first. The older response then arrives after
        // it and must be discarded using its retained request identity.
        fake.enqueue(try relaySnapshot(messageID: "list-archive", sequence: 2, title: "Archive"))
        fake.enqueue(try relaySnapshot(messageID: "list-active", sequence: 3, title: "Active"))
        fake.enqueue(try relaySnapshot(messageID: "snapshot-push-test", sequence: 4, title: "Push"))

        var snapshots: [String] = []
        for _ in 0..<10 {
            guard let event = try await iterator.next() else { break }
            if case .sessionSnapshot = event.kind {
                snapshots.append(event.envelope.messageId)
                if snapshots.count == 2 { break }
            }
        }
        XCTAssertEqual(snapshots, ["list-archive", "snapshot-push-test"])
        await connection.disconnect()
    }

    private func relaySnapshot(messageID: String, sequence: Int64, title: String) throws -> URLSessionWebSocketTask.Message {
        let event = DSHEvent(envelope: DSHEnvelope(
            messageId: messageID, deviceId: "device", machineId: "machine", sequence: sequence,
            type: "session.created", payload: .object([
                "id": .string(title.lowercased()), "title": .string(title),
                "updatedAt": .number(Double(sequence)),
            ])
        ))
        let relay = try DSHRelayPayloadMessage.wrapping(machineId: "machine", sender: .machine, body: event)
        return .data(try JSONEncoder().encode(relay))
    }
}

private final class RecordingWebSocketTask: DSHWebSocketTasking, @unchecked Sendable {
    private(set) var resumeCount = 0
    private(set) var sentCommands: [DSHCommand] = []
    var responseStatusCode: Int?
    var closeCodeRawValue: Int?
    var receiveError: Error?
    private var receiveContinuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var sentReady = false
    private var additionalMessages: [URLSessionWebSocketTask.Message]

    init(additionalMessages: [URLSessionWebSocketTask.Message] = []) {
        self.additionalMessages = additionalMessages
    }

    func resume() { resumeCount += 1 }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        receiveContinuation?.resume(throwing: DSHWebSocketError.closed)
        receiveContinuation = nil
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let data: Data
        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: throw DSHWebSocketError.invalidMessage }
        let relay = try DSHRelayMessage(from: data)
        guard case .payload(let payload) = relay,
              payload.sender == .device else { return }
        sentCommands.append(try payload.decodeBody(DSHCommand.self))
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if let receiveError { throw receiveError }
        if !sentReady {
            sentReady = true
            let ready = DSHRelayReadyMessage(type: "relay.ready", machineId: "machine", role: .device,
                                             connectionId: "connection", serverTime: 1)
            return .data(try JSONEncoder().encode(ready))
        }
        if !additionalMessages.isEmpty { return additionalMessages.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in receiveContinuation = continuation }
    }

    func enqueue(_ message: URLSessionWebSocketTask.Message) {
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(returning: message)
        } else {
            additionalMessages.append(message)
        }
    }
}

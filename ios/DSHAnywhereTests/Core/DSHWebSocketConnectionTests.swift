import XCTest
@testable import DSHAnywhere

final class DSHWebSocketConnectionTests: XCTestCase {
    func testBackoffIsExponentialAndCapped() {
        let backoff = DSHExponentialBackoff(initialNanoseconds: 10, maximumNanoseconds: 25)
        XCTAssertEqual(backoff.delayNanoseconds(for: 1), 10)
        XCTAssertEqual(backoff.delayNanoseconds(for: 2), 20)
        XCTAssertEqual(backoff.delayNanoseconds(for: 3), 25)
        XCTAssertEqual(backoff.delayNanoseconds(for: 0), 0)
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
        XCTAssertEqual(commands[0].payload, .object(["lastSequence": .number(7)]))
        XCTAssertEqual(commands[1].type, "session.list")
        XCTAssertEqual(commands[1].deviceId, "device")
        XCTAssertEqual(commands[1].machineId, "machine")
        XCTAssertEqual(commands[1].payload, .object(["includeArchived": .bool(false)]))
        await connection.disconnect()
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
}

private final class RecordingWebSocketTask: DSHWebSocketTasking, @unchecked Sendable {
    private(set) var resumeCount = 0
    private(set) var sentCommands: [DSHCommand] = []
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
        if !sentReady {
            sentReady = true
            let ready = DSHRelayReadyMessage(type: "relay.ready", machineId: "machine", role: .device,
                                             connectionId: "connection", serverTime: 1)
            return .data(try JSONEncoder().encode(ready))
        }
        if !additionalMessages.isEmpty { return additionalMessages.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in receiveContinuation = continuation }
    }
}

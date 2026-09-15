import Foundation

public enum DSHConnectionState: Sendable, Equatable, Codable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)

    private enum CodingKeys: String, CodingKey { case state, attempt, message }
    private enum StateName: String, Codable { case disconnected, connecting, connected, reconnecting, failed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(StateName.self, forKey: .state) {
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .reconnecting: self = .reconnecting(attempt: try c.decode(Int.self, forKey: .attempt))
        case .failed: self = .failed(try c.decode(String.self, forKey: .message))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .disconnected: try c.encode(StateName.disconnected, forKey: .state)
        case .connecting: try c.encode(StateName.connecting, forKey: .state)
        case .connected: try c.encode(StateName.connected, forKey: .state)
        case .reconnecting(let attempt):
            try c.encode(StateName.reconnecting, forKey: .state); try c.encode(attempt, forKey: .attempt)
        case .failed(let message):
            try c.encode(StateName.failed, forKey: .state); try c.encode(message, forKey: .message)
        }
    }
}

public struct DSHExponentialBackoff: Sendable, Equatable {
    public let initialNanoseconds: UInt64
    public let maximumNanoseconds: UInt64
    public let multiplier: Double

    public init(initialNanoseconds: UInt64 = 500_000_000,
                maximumNanoseconds: UInt64 = 30_000_000_000,
                multiplier: Double = 2) {
        self.initialNanoseconds = initialNanoseconds
        self.maximumNanoseconds = maximumNanoseconds
        self.multiplier = multiplier
    }

    public func delayNanoseconds(for attempt: Int) -> UInt64 {
        guard attempt > 0 else { return 0 }
        let scaled = Double(initialNanoseconds) * pow(multiplier, Double(attempt - 1))
        return min(maximumNanoseconds, UInt64(min(scaled, Double(UInt64.max))))
    }
}

public protocol DSHWebSocketTasking: AnyObject, Sendable {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
}

extension URLSessionWebSocketTask: DSHWebSocketTasking {
    public func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.send(message) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    public func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>) in
            self.receive { result in continuation.resume(with: result) }
        }
    }
}

public enum DSHWebSocketError: Error, LocalizedError, Sendable, Equatable {
    case notConnected
    case invalidMessage
    case unsupportedProtocolVersion(Int)
    case unauthorizedRelayRole
    case relay(code: String, message: String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "The Relay WebSocket is not connected."
        case .invalidMessage: return "The Relay WebSocket message is not valid protocol JSON."
        case .unsupportedProtocolVersion(let version): return "Unsupported protocol version \(version)."
        case .unauthorizedRelayRole: return "The Relay authenticated this connection with an unexpected role."
        case .relay(let code, let message): return "Relay error \(code): \(message)"
        case .closed: return "The Relay WebSocket connection is closed."
        }
    }
}

public struct DSHWebSocketConfiguration: Sendable, Equatable {
    /// `wss://relay.example/v1/connect`, rather than a direct Harness socket.
    public let url: URL
    public let bearerToken: String
    public let deviceId: String
    public let machineId: String
    public let backoff: DSHExponentialBackoff
    /// nil means retry until explicitly disconnected.  A finite value is
    /// useful for previews and deterministic tests.
    public let maximumReconnectAttempts: Int?

    public init(url: URL, bearerToken: String, deviceId: String, machineId: String,
                backoff: DSHExponentialBackoff = .init(), maximumReconnectAttempts: Int? = nil) {
        self.url = url; self.bearerToken = bearerToken; self.deviceId = deviceId
        self.machineId = machineId; self.backoff = backoff
        self.maximumReconnectAttempts = maximumReconnectAttempts
    }
}

/// Owns the Relay socket. Only machine-originated payloads for the paired
/// machine become `DSHEvent`s; Relay control traffic never reaches the store.
public actor DSHWebSocketConnection {
    public typealias TaskFactory = @Sendable (URLRequest) -> any DSHWebSocketTasking

    private let configuration: DSHWebSocketConfiguration
    private let makeTask: TaskFactory
    private var socket: (any DSHWebSocketTasking)?
    private var runner: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<DSHEvent, Error>.Continuation?
    private var activeStream: AsyncThrowingStream<DSHEvent, Error>?
    private var stopped = false
    private var _state: DSHConnectionState = .disconnected
    private var _lastSequence: Int64

    public init(configuration: DSHWebSocketConfiguration,
                lastSequence: Int64 = 0,
                taskFactory: @escaping TaskFactory = { URLSession.shared.webSocketTask(with: $0) }) {
        self.configuration = configuration
        self._lastSequence = lastSequence
        self.makeTask = taskFactory
    }

    public var state: DSHConnectionState { _state }
    public var lastSequence: Int64 { _lastSequence }

    /// Starts one receive stream. Calling connect again returns the existing
    /// stream while a connection is active.
    public func connect() -> AsyncThrowingStream<DSHEvent, Error> {
        if let activeStream { return activeStream }
        stopped = false
        let stream = AsyncThrowingStream<DSHEvent, Error> { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.disconnect() }
            }
        }
        activeStream = stream
        runner = Task { [weak self] in await self?.run() }
        return stream
    }

    public func disconnect() {
        stopped = true
        runner?.cancel()
        runner = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        _state = .disconnected
        yieldControl(type: "transport.state", value: _state)
        continuation?.finish()
        continuation = nil
        activeStream = nil
    }

    /// The UI may construct placeholder identifiers. The paired identity is
    /// always substituted here before the command leaves the phone.
    public func send(_ command: DSHCommand) async throws {
        // The receive loop deliberately keeps the stream alive while the
        // URLSession task reconnects. A user can tap Send during that short
        // window, so wait for the next relay.ready handshake instead of
        // failing immediately with the misleading "not connected" alert.
        let deadline = Date().addingTimeInterval(10)
        while (_state != .connected || socket == nil) && !stopped {
            if Date() >= deadline { throw DSHWebSocketError.notConnected }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !stopped, let socket else { throw DSHWebSocketError.notConnected }
        try await sendRelay(normalized(command), over: socket)
    }

    private func run() async {
        var attempt = 0
        while !stopped && !Task.isCancelled {
            _state = attempt == 0 ? .connecting : .reconnecting(attempt: attempt)
            yieldControl(type: "transport.state", value: _state)
            do {
                var request = URLRequest(url: configuration.url)
                request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
                request.setValue("dsh-anywhere/1", forHTTPHeaderField: "User-Agent")
                let task = makeTask(request)
                socket = task
                task.resume()
                var didReceiveReady = false
                while !stopped && !Task.isCancelled {
                    let message = try await task.receive()
                    if try await consume(message, over: task) { didReceiveReady = true; attempt = 0 }
                }
                if didReceiveReady { attempt = max(attempt, 1) }
            } catch is CancellationError {
                break
            } catch {
                socket = nil
                guard !stopped && !Task.isCancelled else { break }
                attempt += 1
                if let maximum = configuration.maximumReconnectAttempts, attempt > maximum {
                    _state = .failed(error.localizedDescription)
                    yieldControl(type: "transport.state", value: _state)
                    continuation?.finish(throwing: error)
                    continuation = nil
                    return
                }
                _state = .reconnecting(attempt: attempt)
                yieldControl(type: "transport.state", value: _state)
                let delay = configuration.backoff.delayNanoseconds(for: attempt)
                do { try await Task.sleep(nanoseconds: delay) }
                catch { break }
            }
        }
        if !stopped {
            _state = .failed(DSHWebSocketError.closed.localizedDescription)
            yieldControl(type: "transport.state", value: _state)
        }
    }

    /// Returns true for the Relay handshake, which is the point at which a
    /// resume command can be safely routed to a connected Mac.
    private func consume(_ message: URLSessionWebSocketTask.Message,
                         over task: any DSHWebSocketTasking) async throws -> Bool {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw DSHWebSocketError.invalidMessage
        }
        let relay: DSHRelayMessage
        do { relay = try DSHRelayMessage(from: data) }
        catch { throw DSHWebSocketError.invalidMessage }

        switch relay {
        case .ready(let ready):
            guard ready.machineId == configuration.machineId, ready.role == .device else {
                throw DSHWebSocketError.unauthorizedRelayRole
            }
            _state = .connected
            yieldControl(type: "transport.state", value: _state)
            try await sendRelay(.resume(deviceId: configuration.deviceId, machineId: configuration.machineId,
                                        lastSequence: _lastSequence), over: task)
            // A Relay handshake is the only readiness signal guaranteed on
            // every connection. Request the authoritative session list here,
            // rather than relying on SwiftUI onAppear or on a replayed local
            // connection.ready event that may no longer be buffered.
            try await sendRelay(.listSessions(deviceId: configuration.deviceId,
                                              machineId: configuration.machineId), over: task)
            return true
        case .presence(let presence):
            if presence.machineId == configuration.machineId, presence.role == .machine {
                yieldControl(type: "machine.presence", value: presence.online)
            }
            return false
        case .error(let error):
            throw DSHWebSocketError.relay(code: error.code, message: error.message)
        case .payload(let payload):
            // The Relay may notify this device about control messages. Only
            // events from its paired machine belong to this client stream.
            guard payload.sender == .machine, payload.machineId == configuration.machineId,
                  let event = try? payload.decodeBody(DSHEvent.self) else { return false }
            guard event.envelope.version == 1 else {
                throw DSHWebSocketError.unsupportedProtocolVersion(event.envelope.version)
            }
            if event.startsNewSequenceEpoch(comparedTo: _lastSequence) {
                // A Connector restart resets its in-memory replay sequence.  A
                // full session snapshot is also authoritative: it is sent in
                // direct response to a user refresh, and may be the first
                // event seen after the Connector has restarted before it can
                // replay connection.ready.
                _lastSequence = 0
            }
            if event.sequence > _lastSequence { _lastSequence = event.sequence }
            continuation?.yield(event)
            return false
        }
    }

    private func normalized(_ command: DSHCommand) -> DSHCommand {
        DSHCommand(version: command.version, requestId: command.requestId,
                   deviceId: configuration.deviceId, machineId: configuration.machineId,
                   sessionId: command.sessionId, timestamp: command.timestamp,
                   type: command.type, payload: command.payload)
    }

    private func sendRelay(_ command: DSHCommand, over task: any DSHWebSocketTasking) async throws {
        let payload = try DSHRelayPayloadMessage.wrapping(machineId: configuration.machineId,
                                                           sender: .device, body: command)
        try await task.send(.data(try JSONEncoder().encode(payload)))
    }

    /// Feeds Relay control-plane state through the same batched UI stream as
    /// Harness events without consuming a Connector sequence number.
    private func yieldControl<T: Encodable>(type: String, value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let payload = try? JSONDecoder().decode(DSHJSONValue.self, from: data) else { return }
        continuation?.yield(DSHEvent(envelope: DSHEnvelope(
            messageId: UUID().uuidString,
            deviceId: configuration.deviceId,
            machineId: configuration.machineId,
            sequence: 0,
            type: type,
            payload: payload
        )))
    }
}

private extension DSHEvent {
    func startsNewSequenceEpoch(comparedTo lastSequence: Int64) -> Bool {
        guard sequence <= lastSequence else { return false }
        switch kind {
        case .connectionReady, .sessionSnapshot:
            return true
        default:
            return false
        }
    }
}

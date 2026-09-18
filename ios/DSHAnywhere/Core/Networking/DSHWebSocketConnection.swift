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
        guard maximumNanoseconds > 0 else { return 0 }
        let cappedInitial = min(initialNanoseconds, maximumNanoseconds)
        guard cappedInitial < maximumNanoseconds else { return maximumNanoseconds }
        // Invalid configuration must degrade to a finite first delay rather
        // than allowing NaN or infinity to reach UInt64's trapping conversion.
        guard multiplier.isFinite, multiplier > 0 else { return cappedInitial }
        let scaled = Double(cappedInitial) * pow(multiplier, Double(attempt - 1))
        // Compare before converting. UInt64(Double) traps when the floating
        // value is outside the representable range, and the cap must protect
        // that conversion as well as the returned value.
        guard scaled.isFinite, scaled < Double(maximumNanoseconds) else {
            return maximumNanoseconds
        }
        return UInt64(scaled)
    }
}

public protocol DSHWebSocketTasking: AnyObject, Sendable {
    /// URLSession exposes these after a failed handshake or remote close.
    /// Test doubles may leave them nil; ordinary transport errors remain
    /// retryable unless the server gives us an explicit auth signal.
    var responseStatusCode: Int? { get }
    var closeCodeRawValue: Int? { get }
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
}

public extension DSHWebSocketTasking {
    var responseStatusCode: Int? { nil }
    var closeCodeRawValue: Int? { nil }
}

extension URLSessionWebSocketTask: DSHWebSocketTasking {
    public var responseStatusCode: Int? { (response as? HTTPURLResponse)?.statusCode }
    public var closeCodeRawValue: Int? { closeCode.rawValue }

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
    case authenticationRequired
    case eventBufferOverflow
    case relay(code: String, message: String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "The Relay WebSocket is not connected."
        case .invalidMessage: return "The Relay WebSocket message is not valid protocol JSON."
        case .unsupportedProtocolVersion(let version): return "Unsupported protocol version \(version)."
        case .unauthorizedRelayRole: return "The Relay authenticated this connection with an unexpected role."
        case .authenticationRequired: return "The Relay credentials are no longer valid. Pair this iPhone again."
        case .eventBufferOverflow: return "The Relay event buffer overflowed; reconnecting to resynchronize."
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
    private static let maxBufferedEvents = 512
    private static let unsolicitedSessionSnapshotPrefix = "snapshot-push-"

    private let configuration: DSHWebSocketConfiguration
    private let makeTask: TaskFactory
    private var socket: (any DSHWebSocketTasking)?
    private var runner: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<DSHEvent, Error>.Continuation?
    private var activeStream: AsyncThrowingStream<DSHEvent, Error>?
    private var stopped = false
    private var streamBufferOverflowed = false
    private var _state: DSHConnectionState = .disconnected
    private var _lastSequence: Int64
    /// A restart resets Connector sequence numbers. Only a snapshot that
    /// answers one of this device's own session-list requests may establish a
    /// new epoch without a preceding connection.ready; arbitrary replayed
    /// snapshots are deliberately ignored when they are older.
    private enum SessionSnapshotRequestStatus {
        case pending
        case accepted
        case expired
    }

    private struct SessionSnapshotRequest {
        let generation: Int
        var status: SessionSnapshotRequestStatus
    }

    /// Keep completed/expired request identities long enough to reject a late
    /// response. An unknown snapshot is only accepted when the Connector marks
    /// it as an unsolicited push; it is never inferred from a missing map key.
    private var sessionSnapshotRequests: [String: SessionSnapshotRequest] = [:]
    private var latestSessionSnapshotRequestGeneration = 0

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
        streamBufferOverflowed = false
        let stream = AsyncThrowingStream<DSHEvent, Error>(bufferingPolicy: .bufferingOldest(Self.maxBufferedEvents)) { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.streamDidTerminate() }
            }
        }
        activeStream = stream
        runner = Task { [weak self] in await self?.run() }
        return stream
    }

    public func disconnect() {
        disconnect(preserveFailure: false)
    }

    private func streamDidTerminate() {
        let preserveFailure: Bool
        if case .failed = _state { preserveFailure = true }
        else { preserveFailure = false }
        disconnect(preserveFailure: preserveFailure)
    }

    private func disconnect(preserveFailure: Bool) {
        stopped = true
        streamBufferOverflowed = false
        runner?.cancel()
        runner = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        if !preserveFailure {
            _state = .disconnected
            yieldControl(type: "transport.state", value: _state)
        }
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
        let normalized = normalized(command)
        let generation = rememberSessionSnapshotRequestIfNeeded(normalized)
        do {
            try await sendRelay(normalized, over: socket)
        } catch {
            revokeSessionSnapshotRequest(normalized.requestId, generation: generation)
            throw error
        }
    }

    private func run() async {
        var attempt = 0
        while !stopped && !Task.isCancelled {
            _state = attempt == 0 ? .connecting : .reconnecting(attempt: attempt)
            yieldControl(type: "transport.state", value: _state)
            var activeTask: (any DSHWebSocketTasking)?
            do {
                var request = URLRequest(url: configuration.url)
                request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
                request.setValue("dsh-anywhere/1", forHTTPHeaderField: "User-Agent")
                let task = makeTask(request)
                activeTask = task
                socket = task
                defer {
                    // Every receive-loop exit owns and closes exactly the task
                    // it created. Merely dropping our reference can leave a
                    // URLSession WebSocket alive across reconnect attempts.
                    task.cancel(with: .goingAway, reason: nil)
                    if let current = socket,
                       (current as AnyObject) === (task as AnyObject) {
                        socket = nil
                    }
                }
                task.resume()
                var didReceiveReady = false
                while !stopped && !Task.isCancelled {
                    if streamBufferOverflowed { throw DSHWebSocketError.eventBufferOverflow }
                    let message = try await task.receive()
                    if try await consume(message, over: task) { didReceiveReady = true; attempt = 0 }
                }
                if didReceiveReady { attempt = max(attempt, 1) }
            } catch is CancellationError {
                break
            } catch {
                let classifiedError = classifyTransportError(error, task: activeTask)
                guard !stopped && !Task.isCancelled else { break }
                if let socketError = classifiedError as? DSHWebSocketError,
                   case .eventBufferOverflow = socketError {
                    streamBufferOverflowed = false
                }
                if !shouldReconnect(after: classifiedError) {
                    _state = .failed(classifiedError.localizedDescription)
                    yieldControl(type: "transport.state", value: _state)
                    continuation?.finish(throwing: classifiedError)
                    continuation = nil
                    return
                }
                attempt += 1
                if let maximum = configuration.maximumReconnectAttempts, attempt > maximum {
                    _state = .failed(classifiedError.localizedDescription)
                    yieldControl(type: "transport.state", value: _state)
                    continuation?.finish(throwing: classifiedError)
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

    private func shouldReconnect(after error: Error) -> Bool {
        guard let socketError = error as? DSHWebSocketError else { return true }
        switch socketError {
        case .notConnected, .closed:
            return true
        case .invalidMessage, .unsupportedProtocolVersion, .unauthorizedRelayRole,
             .authenticationRequired, .relay:
            // Retrying unchanged credentials or an incompatible wire message
            // cannot heal the connection and otherwise becomes a tight loop.
            return false
        case .eventBufferOverflow:
            return true
        }
    }

    private func classifyTransportError(_ error: Error, task: (any DSHWebSocketTasking)?) -> Error {
        if let status = task?.responseStatusCode, status == 401 || status == 403 {
            return DSHWebSocketError.authenticationRequired
        }
        if let closeCode = task?.closeCodeRawValue, closeCode == 4401 || closeCode == 4403 {
            return DSHWebSocketError.authenticationRequired
        }
        if let urlError = error as? URLError, urlError.code == .userAuthenticationRequired {
            return DSHWebSocketError.authenticationRequired
        }
        return error
    }

    /// Returns true for the Relay handshake, which is the point at which a
    /// resume command can be safely routed to a connected Mac.
    private func consume(_ message: URLSessionWebSocketTask.Message,
                         over task: any DSHWebSocketTasking) async throws -> Bool {
        if streamBufferOverflowed { throw DSHWebSocketError.eventBufferOverflow }
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
            // Requests from a dead socket can never receive a useful reply.
            // The fresh handshake list below becomes the only list authority.
            sessionSnapshotRequests.removeAll(keepingCapacity: false)
            yieldControl(type: "transport.state", value: _state)
            try await sendRelay(.resume(deviceId: configuration.deviceId, machineId: configuration.machineId,
                                        lastSequence: _lastSequence), over: task)
            // A Relay handshake is the only readiness signal guaranteed on
            // every connection. Request the authoritative session list here,
            // rather than relying on SwiftUI onAppear or on a replayed local
            // connection.ready event that may no longer be buffered.
            let list = DSHCommand.listSessions(deviceId: configuration.deviceId,
                                               machineId: configuration.machineId)
            let generation = rememberSessionSnapshotRequestIfNeeded(list)
            do {
                try await sendRelay(list, over: task)
            } catch {
                revokeSessionSnapshotRequest(list.requestId, generation: generation)
                throw error
            }
            return true
        case .presence(let presence):
            if presence.machineId == configuration.machineId, presence.role == .machine {
                yieldControl(type: "machine.presence", value: presence.online)
            }
            return false
        case .error(let error):
            if error.code == "target_unavailable" {
                // The Relay socket is healthy; only the paired Mac is offline.
                // Keep this connection so its machine-presence event can wake
                // the UI as soon as a Connector appears.
                sessionSnapshotRequests.removeAll(keepingCapacity: false)
                yieldControl(type: "machine.presence", value: false)
                return false
            }
            throw DSHWebSocketError.relay(code: error.code, message: error.message)
        case .payload(let payload):
            // The Relay may notify this device about control messages. Only
            // events from its paired machine belong to this client stream.
            guard payload.sender == .machine, payload.machineId == configuration.machineId,
                  let event = try? payload.decodeBody(DSHEvent.self) else { return false }
            guard event.envelope.version == 1 else {
                throw DSHWebSocketError.unsupportedProtocolVersion(event.envelope.version)
            }
            let snapshotRequest = event.isSessionSnapshot
                ? sessionSnapshotRequests[event.envelope.messageId]
                : nil
            let snapshotGeneration = snapshotRequest?.generation
            let isCorrelatedSnapshot = snapshotRequest?.status == .pending &&
                snapshotGeneration == latestSessionSnapshotRequestGeneration
            // Two refreshes can cross on the wire (for example, opening
            // Archives while the initial list is still in flight). The older
            // result is still valid server data, but it is not the answer to
            // the current screen state and must not overwrite it.
            if event.isSessionSnapshot {
                if let snapshotRequest {
                    guard snapshotRequest.status == .pending else { return false }
                    guard snapshotRequest.generation == latestSessionSnapshotRequestGeneration else {
                        sessionSnapshotRequests[event.envelope.messageId]?.status = .expired
                        return false
                    }
                    sessionSnapshotRequests[event.envelope.messageId]?.status = .accepted
                    // Older requests may still be in flight. Retain their ids,
                    // but mark them expired so their late responses are dropped.
                    for (requestID, request) in sessionSnapshotRequests
                    where request.generation < latestSessionSnapshotRequestGeneration && request.status == .pending {
                        sessionSnapshotRequests[requestID]?.status = .expired
                    }
                } else {
                    // Connector-generated unsolicited snapshots carry an
                    // explicit prefix. A missing request id alone is not proof
                    // that a snapshot is a valid push, which closes the stale
                    // response path after the request table is pruned.
                    guard event.envelope.messageId.hasPrefix(Self.unsolicitedSessionSnapshotPrefix),
                          !hasPendingSessionSnapshotRequest else { return false }
                }
            }
            // During a current list request, a replay/presence snapshot has no
            // request correlation. Wait for the current answer instead of
            // briefly painting whatever old list happened to arrive first.
            if case .protocolError = event.kind,
               let failedRequest = sessionSnapshotRequests[event.envelope.messageId],
               failedRequest.status == .pending,
               failedRequest.generation == latestSessionSnapshotRequestGeneration {
                sessionSnapshotRequests[event.envelope.messageId]?.status = .expired
            }
            let establishesEpoch = event.startsNewSequenceEpoch(comparedTo: _lastSequence,
                                                                  matchingSessionListRequest: isCorrelatedSnapshot)
            let delivered = continuation?.yield(DSHEvent(envelope: event.envelope,
                                                          establishesSequenceEpoch: establishesEpoch))
            guard let delivered else { throw DSHWebSocketError.closed }
            switch delivered {
            case .enqueued:
                // Advance the resume cursor only after the event was accepted
                // by the bounded stream. Advancing before `yield` would make
                // a dropped event unrecoverable on the next connection.
                if establishesEpoch { _lastSequence = 0 }
                if event.sequence > _lastSequence { _lastSequence = event.sequence }
            case .dropped:
                // Keep the previous cursor and reconnect. Connector replay
                // will then resend the first event that did not fit.
                streamBufferOverflowed = true
                throw DSHWebSocketError.eventBufferOverflow
            case .terminated:
                throw DSHWebSocketError.closed
            @unknown default:
                throw DSHWebSocketError.closed
            }
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

    @discardableResult
    private func rememberSessionSnapshotRequestIfNeeded(_ command: DSHCommand) -> Int? {
        guard command.type == "session.list" else { return nil }
        latestSessionSnapshotRequestGeneration += 1
        let generation = latestSessionSnapshotRequestGeneration
        sessionSnapshotRequests[command.requestId] = SessionSnapshotRequest(generation: generation, status: .pending)
        // A timed-out response must not turn an unrelated future event into a
        // reset. The bounded set also preserves the most recent refreshes when
        // several pull-to-refresh gestures race.
        if sessionSnapshotRequests.count > 24 {
            let cutoff = latestSessionSnapshotRequestGeneration - 12
            sessionSnapshotRequests = sessionSnapshotRequests.filter { $0.value.generation >= cutoff || $0.value.status == .pending }
        }
        return generation
    }

    private func revokeSessionSnapshotRequest(_ requestID: String, generation: Int?) {
        guard let generation,
              let request = sessionSnapshotRequests[requestID],
              request.generation == generation,
              request.status == .pending else { return }
        sessionSnapshotRequests.removeValue(forKey: requestID)
    }

    private var hasPendingSessionSnapshotRequest: Bool {
        sessionSnapshotRequests.values.contains { $0.status == .pending }
    }

    /// Feeds Relay control-plane state through the same batched UI stream as
    /// Harness events without consuming a Connector sequence number.
    private func yieldControl<T: Encodable>(type: String, value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let payload = try? JSONDecoder().decode(DSHJSONValue.self, from: data) else { return }
        let delivered = continuation?.yield(DSHEvent(envelope: DSHEnvelope(
            messageId: UUID().uuidString,
            deviceId: configuration.deviceId,
            machineId: configuration.machineId,
            sequence: 0,
            type: type,
            payload: payload
        )))
        if let delivered, case .dropped = delivered {
            // Control events share the bounded stream with business events.
            // A dropped control event still means the consumer may have
            // missed an adjacent durable event, so force a replay from the
            // last accepted sequence on the next connection.
            streamBufferOverflowed = true
        }
    }
}

private extension DSHEvent {
    var isSessionSnapshot: Bool {
        if case .sessionSnapshot = kind { return true }
        return false
    }

    func startsNewSequenceEpoch(comparedTo lastSequence: Int64,
                                matchingSessionListRequest: Bool) -> Bool {
        guard sequence <= lastSequence else { return false }
        if matchingSessionListRequest { return true }
        switch kind {
        // A delayed/replayed list can otherwise reset the transport cursor and
        // republish stale home rows during launch. A real restart either emits
        // connection.ready or answers our just-sent list request above.
        case .connectionReady:
            return true
        default:
            return false
        }
    }
}

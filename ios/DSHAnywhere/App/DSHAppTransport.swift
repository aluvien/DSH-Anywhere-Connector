import Foundation

/// The small boundary between the native UI and the machine connection.
/// Production code can provide a WebSocket-backed implementation, while
/// previews and tests can inject the in-memory implementation below.
protocol DSHAppTransport: Sendable {
    func pair(serverAddress: String, machineId: String, pairingSecret: String, deviceName: String) async throws -> DSHRemoteProfile
    func connect() async -> AsyncThrowingStream<DSHEvent, Error>
    func send(_ command: DSHCommand) async throws
    func disconnect() async
    func forgetPairing() async throws
}

actor DSHRemoteTransport: DSHAppTransport {
    private static let profileKey = "dsh-anywhere.relay-profile"
    private let tokenStore: any DSHTokenStore
    private var connection: DSHWebSocketConnection?

    init(tokenStore: any DSHTokenStore = DSHKeychainTokenStore()) {
        self.tokenStore = tokenStore
    }

    nonisolated static var isConfigured: Bool { UserDefaults.standard.data(forKey: profileKey) != nil }

    func pair(serverAddress: String, machineId: String, pairingSecret: String, deviceName: String) async throws -> DSHRemoteProfile {
        let baseURL = try DSHAPIClient.relayBaseURL(from: serverAddress)
        let result = try await DSHAPIClient(relayBaseURL: baseURL).pair(
            machineId: machineId, pairingSecret: pairingSecret, deviceName: deviceName
        )
        try tokenStore.save(result.token, account: result.profile.deviceId)
        UserDefaults.standard.set(try JSONEncoder().encode(result.profile), forKey: Self.profileKey)
        return result.profile
    }

    func connect() async -> AsyncThrowingStream<DSHEvent, Error> {
        let credentials = try? loadCredentials()
        guard let (profile, token) = credentials else {
            return AsyncThrowingStream { $0.finish(throwing: DSHAPIError.missingCredentials) }
        }
        if let connection { return await connection.connect() }
        var components = URLComponents(url: profile.relayBaseURL, resolvingAgainstBaseURL: false)
        let socketScheme = components?.scheme == "https" ? "wss" : "ws"
        components?.scheme = socketScheme
        guard var relayURL = components?.url else {
            return AsyncThrowingStream { $0.finish(throwing: DSHAPIError.invalidServerURL) }
        }
        relayURL.append(path: "v1/connect")
        let socket = DSHWebSocketConnection(configuration: .init(
            url: relayURL, bearerToken: token, deviceId: profile.deviceId, machineId: profile.machineId
        ))
        connection = socket
        return await socket.connect()
    }

    func send(_ command: DSHCommand) async throws {
        guard let connection else { throw DSHWebSocketError.notConnected }
        try await connection.send(command)
    }

    func disconnect() async {
        await connection?.disconnect()
        connection = nil
    }

    func forgetPairing() async throws {
        await disconnect()
        if let data = UserDefaults.standard.data(forKey: Self.profileKey),
           let profile = try? JSONDecoder().decode(DSHRemoteProfile.self, from: data) {
            try tokenStore.delete(account: profile.deviceId)
        }
        UserDefaults.standard.removeObject(forKey: Self.profileKey)
    }

    private func loadCredentials() throws -> (DSHRemoteProfile, String) {
        guard let data = UserDefaults.standard.data(forKey: Self.profileKey),
              let profile = try? JSONDecoder().decode(DSHRemoteProfile.self, from: data),
              let token = try tokenStore.read(account: profile.deviceId) else {
            throw DSHAPIError.missingCredentials
        }
        return (profile, token)
    }
}

/// A deterministic transport used by SwiftUI previews and by the first-run
/// app shell before a machine has been paired.
actor DSHPreviewTransport: DSHAppTransport {
    private var continuation: AsyncThrowingStream<DSHEvent, Error>.Continuation?
    private var nextSequence: Int64 = 1
    private let deviceID = "preview-device"
    private let machineID = "preview-machine"

    func pair(serverAddress: String, machineId: String, pairingSecret: String, deviceName: String) async throws -> DSHRemoteProfile {
        DSHRemoteProfile(relayBaseURL: URL(string: "https://preview.invalid")!,
                         deviceId: deviceID, machineId: machineID, machineName: "Preview Mac")
    }

    func connect() async -> AsyncThrowingStream<DSHEvent, Error> {
        let pair = AsyncThrowingStream<DSHEvent, Error>.makeStream()
        continuation = pair.continuation
        emit(type: "connection.ready", payload: .object([:]))
        return pair.stream
    }

    func send(_ command: DSHCommand) async throws {
        switch command.type {
        case "session.create":
            let id = UUID().uuidString
            let title = value("title", from: command.payload) ?? "New session"
            emit(type: "session.created", sessionID: id,
                 payload: .object(["id": .string(id), "title": .string(title), "updatedAt": .number(Date().timeIntervalSince1970 * 1_000)]))
        case "prompt.send":
            guard let sessionID = command.sessionId,
                  let text = value("text", from: command.payload) else { return }
            let userID = UUID().uuidString
            emit(type: "user.message.accepted", sessionID: sessionID,
                 payload: .object(["id": .string(userID), "role": .string("user"), "markdown": .string(text)]))
            let toolID = UUID().uuidString
            emit(type: "tool.started", sessionID: sessionID,
                 payload: .object(["id": .string(toolID), "name": .string("deepseek_harness"), "status": .string("running"), "detail": .string("Working on your request")]))
            let messageID = UUID().uuidString
            emit(type: "assistant.message.delta", sessionID: sessionID,
                 payload: .object(["messageId": .string(messageID), "text": .string("I received your request. ")]))
            emit(type: "assistant.message.completed", sessionID: sessionID,
                 payload: .object(["id": .string(messageID), "role": .string("assistant"), "markdown": .string("I received your request. The preview transport is ready for a real Harness connection.")]))
            emit(type: "tool.completed", sessionID: sessionID,
                 payload: .object(["id": .string(toolID), "name": .string("deepseek_harness"), "status": .string("completed"), "detail": .string("Finished")]))
            emit(type: "turn.state.changed", sessionID: sessionID,
                 payload: .object(["sessionId": .string(sessionID), "state": .string("idle")]))
        case "approval.decide":
            if let approvalID = value("approvalId", from: command.payload) {
                let allowed = boolValue("allow", from: command.payload) ?? false
                emit(type: "approval.resolved", sessionID: command.sessionId,
                     payload: .object(["id": .string(approvalID), "allowed": .bool(allowed)]))
            }
        default:
            break
        }
    }

    func disconnect() async {
        continuation?.finish()
        continuation = nil
    }

    func forgetPairing() async throws { await disconnect() }

    private func emit(type: String, sessionID: String? = nil, payload: DSHJSONValue) {
        let envelope = DSHEnvelope(messageId: UUID().uuidString, deviceId: deviceID,
                                    machineId: machineID, sessionId: sessionID,
                                    sequence: nextSequence, type: type, payload: payload)
        nextSequence += 1
        continuation?.yield(DSHEvent(envelope: envelope))
    }

    private func value(_ key: String, from payload: DSHJSONValue) -> String? {
        guard case .object(let object) = payload, case .string(let value) = object[key] else { return nil }
        return value
    }

    private func boolValue(_ key: String, from payload: DSHJSONValue) -> Bool? {
        guard case .object(let object) = payload, case .bool(let value) = object[key] else { return nil }
        return value
    }
}

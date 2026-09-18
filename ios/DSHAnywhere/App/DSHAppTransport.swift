import Foundation

/// The small boundary between the native UI and the machine connection.
/// Production code can provide a WebSocket-backed implementation, while
/// previews and tests can inject the in-memory implementation below.
protocol DSHAppTransport: Sendable {
    func pair(serverAddress: String, machineId: String, credential: DSHPairingCredential, deviceName: String) async throws -> DSHRemoteProfile
    func connect() async -> AsyncThrowingStream<DSHEvent, Error>
    /// Keeps the handshake/resume snapshot aligned with the visible archive filter.
    func setIncludeArchived(_ value: Bool) async
    func send(_ command: DSHCommand) async throws
    func disconnect() async
    func forgetPairing() async throws
    /// Chooses which paired Mac subsequent connections target.
    func setActiveMachine(_ machineId: String) async
    /// Forgets one paired Mac, leaving the others intact.
    func removeMachine(_ machineId: String) async throws
    /// Devices paired to the active machine, straight from the Relay.
    func pairedDevices() async throws -> [DSHRelayDevice]
    /// Revokes one device. The Relay refuses to let a device revoke itself.
    func revokeDevice(_ deviceId: String) async throws
}

private struct DSHRelayUpgradeRequired: LocalizedError {
    var errorDescription: String? { "请先升级 Relay 服务后再使用项目、模式或重命名功能。已有会话仍可正常使用。" }
}

actor DSHRemoteTransport: DSHAppTransport {
    private let tokenStore: any DSHTokenStore
    private let store: DSHProfileStore
    private var connection: DSHWebSocketConnection?
    private var relaySchema: (url: URL, revision: Int)?
    private var includeArchivedSessions = false
    /// Invalidates every connect/disconnect operation that is suspended across
    /// an actor `await`.  Actor isolation does not make a multi-step connect
    /// transaction atomic once it awaits URLSession or the socket actor.
    private var connectionGeneration = 0
    /// A later machine choice supersedes an earlier choice even when the
    /// earlier socket's asynchronous cleanup finishes last.
    private var machineSelectionGeneration = 0
    /// The target of the currently suspended machine switch. Deleting an
    /// unrelated profile must not cancel it, but deleting this target must.
    private var pendingMachineSelectionID: String?

    init(tokenStore: any DSHTokenStore = DSHKeychainTokenStore(),
         store: DSHProfileStore = DSHProfileStore()) {
        self.tokenStore = tokenStore
        self.store = store
    }

    nonisolated static var isConfigured: Bool { !DSHProfileStore().profiles.isEmpty }

    func pair(serverAddress: String, machineId: String, credential: DSHPairingCredential, deviceName: String) async throws -> DSHRemoteProfile {
        let baseURL = try DSHAPIClient.relayBaseURL(from: serverAddress)
        let result = try await DSHAPIClient(relayBaseURL: baseURL).pair(
            machineId: machineId, credential: credential, deviceName: deviceName
        )
        try tokenStore.save(result.token, account: result.profile.deviceId)
        // Adds to the machine list rather than replacing it, so pairing a second
        // Mac no longer makes the first one unreachable.
        store.upsert(result.profile)
        return result.profile
    }

    func connect() async -> AsyncThrowingStream<DSHEvent, Error> {
        let credentials = try? loadCredentials()
        guard let (profile, token) = credentials else {
            return AsyncThrowingStream { $0.finish(throwing: DSHAPIError.missingCredentials) }
        }
        let generation = connectionGeneration
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
        await socket.setIncludeArchived(includeArchivedSessions)
        guard generation == connectionGeneration,
              store.activeMachineId == profile.machineId else {
            await socket.disconnect()
            return AsyncThrowingStream { $0.finish() }
        }
        connection = socket
        let stream = await socket.connect()
        guard generation == connectionGeneration,
              store.activeMachineId == profile.machineId,
              connection === socket else {
            if connection === socket { connection = nil }
            await socket.disconnect()
            return AsyncThrowingStream { $0.finish() }
        }
        return stream
    }

    func setIncludeArchived(_ value: Bool) async {
        includeArchivedSessions = value
        await connection?.setIncludeArchived(value)
    }

    func send(_ command: DSHCommand) async throws {
        guard let connection else { throw DSHWebSocketError.notConnected }
        guard let activeProfile = store.activeProfile,
              command.machineId == activeProfile.machineId else {
            throw DSHWebSocketError.machineMismatch
        }
        if ["workspace.catalog", "workspace.create", "mode.catalog", "directory.list", "session.rename"].contains(command.type) {
            try await verifyCatalogRelay()
        }
        var outgoing = command
        if command.type == "session.open",
           case .object(var payload) = command.payload,
           payload["streaming"] != nil,
           ((try? await relaySchemaRevision()) ?? 0) < 8 {
            // Older relays reject unknown fields. Preserve ordinary history
            // and chat even when live-stream support is not deployed there.
            payload.removeValue(forKey: "streaming")
            outgoing = DSHCommand(version: command.version, requestId: command.requestId,
                                  deviceId: command.deviceId, machineId: command.machineId,
                                  sessionId: command.sessionId, timestamp: command.timestamp,
                                  type: command.type, payload: .object(payload))
        }
        try await connection.send(outgoing)
    }

    /// New routed commands require schema 7. A staged rollout must not send
    /// unknown messages to an older Relay and tear down existing chat traffic.
    private func verifyCatalogRelay() async throws {
        guard try await relaySchemaRevision() >= 7 else { throw DSHRelayUpgradeRequired() }
    }

    private func relaySchemaRevision() async throws -> Int {
        guard let profile = store.activeProfile else { throw DSHAPIError.missingCredentials }
        let baseURL = profile.relayBaseURL
        if let relaySchema, relaySchema.url == baseURL { return relaySchema.revision }
        var request = URLRequest(url: baseURL.appending(path: "health"))
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        struct Health: Decodable { let schemaRevision: Int? }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let health = try? JSONDecoder().decode(Health.self, from: data) else {
            throw DSHRelayUpgradeRequired()
        }
        let revision = health.schemaRevision ?? 0
        relaySchema = (baseURL, revision)
        return revision
    }

    func disconnect() async {
        machineSelectionGeneration &+= 1
        pendingMachineSelectionID = nil
        await disconnectConnection()
    }

    private func disconnectConnection() async {
        connectionGeneration &+= 1
        let oldConnection = connection
        connection = nil
        relaySchema = nil
        await oldConnection?.disconnect()
    }

    func forgetPairing() async throws {
        await disconnect()
        guard let profile = store.activeProfile else { return }
        try tokenStore.delete(account: profile.deviceId)
        store.remove(profile.machineId)
    }

    func setActiveMachine(_ machineId: String) async {
        // The socket carries the old machine's identity, so it cannot be reused.
        machineSelectionGeneration &+= 1
        let selection = machineSelectionGeneration
        pendingMachineSelectionID = machineId
        await disconnectConnection()
        guard selection == machineSelectionGeneration else { return }
        store.setActive(machineId)
        pendingMachineSelectionID = nil
    }

    func removeMachine(_ machineId: String) async throws {
        if pendingMachineSelectionID == machineId {
            machineSelectionGeneration &+= 1
            pendingMachineSelectionID = nil
        }
        if store.activeMachineId == machineId { await disconnect() }
        if let profile = store.profiles.first(where: { $0.machineId == machineId }) {
            try tokenStore.delete(account: profile.deviceId)
        }
        store.remove(machineId)
    }

    func pairedDevices() async throws -> [DSHRelayDevice] {
        let (profile, token) = try loadCredentials()
        return try await DSHAPIClient(relayBaseURL: profile.relayBaseURL)
            .devices(machineId: profile.machineId, token: token)
    }

    func revokeDevice(_ deviceId: String) async throws {
        let (profile, token) = try loadCredentials()
        try await DSHAPIClient(relayBaseURL: profile.relayBaseURL)
            .revokeDevice(machineId: profile.machineId, deviceId: deviceId, token: token)
    }

    private func loadCredentials() throws -> (DSHRemoteProfile, String) {
        guard let profile = store.activeProfile,
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

    func pair(serverAddress: String, machineId: String, credential: DSHPairingCredential, deviceName: String) async throws -> DSHRemoteProfile {
        DSHRemoteProfile(relayBaseURL: URL(string: "https://preview.invalid")!,
                         deviceId: deviceID, machineId: machineID, machineName: "Preview Mac")
    }

    func connect() async -> AsyncThrowingStream<DSHEvent, Error> {
        let pair = AsyncThrowingStream<DSHEvent, Error>.makeStream()
        continuation = pair.continuation
        emit(type: "connection.ready", payload: .object([:]))
        return pair.stream
    }

    func setIncludeArchived(_ value: Bool) async {}

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

    func setActiveMachine(_ machineId: String) async {}

    func removeMachine(_ machineId: String) async throws {}

    func pairedDevices() async throws -> [DSHRelayDevice] { [] }

    func revokeDevice(_ deviceId: String) async throws {}

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

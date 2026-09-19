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
    /// Optional local deadline used by durable prompt retries.  Existing
    /// preview/test transports inherit the ordinary send behavior.
    func send(_ command: DSHCommand, notAfter: Date?) async throws
    func disconnect() async
    func forgetPairing() async throws
    /// Chooses which paired Mac subsequent connections target.
    func setActiveMachine(_ machineId: String) async
    /// Forgets one paired Mac, leaving the others intact.
    func removeMachine(_ machineId: String) async throws
    /// Rolls back a locally persisted profile after a post-pairing journal
    /// transaction failed. The production transport also revokes the
    /// provisional Relay device credential created by pair().
    func rollbackPairing(machineId: String) async
    /// Marks a pairing durable after the local profile, transaction journal,
    /// and removal fence have all committed. This closes the compensating
    /// rollback window for the production transport.
    func commitPairing(machineId: String) async
    /// Fences a pairing as locally committed before the final journal write.
    /// The marker is deliberately durable so a crash between that fence and
    /// the final journal write cannot make a valid Relay device look like an
    /// abandoned provisional credential on the next launch.
    func markPairingLocallyCommitted(machineId: String) async -> Bool
    /// Devices paired to the active machine, straight from the Relay.
    func pairedDevices() async throws -> [DSHRelayDevice]
    /// Revokes one device. The Relay refuses to let a device revoke itself.
    func revokeDevice(_ deviceId: String) async throws
    /// Returns the profile store after connect-time pairing recovery. A
    /// recovery pass may revoke the old active profile or promote another Mac,
    /// so AppModel must refresh its published selection before consuming the
    /// returned event stream.
    func profileSnapshot() async -> DSHTransportProfileSnapshot?
}

extension DSHAppTransport {
    func send(_ command: DSHCommand, notAfter: Date?) async throws {
        try await send(command)
    }

    func rollbackPairing(machineId: String) async {}
    func commitPairing(machineId: String) async {}
    func markPairingLocallyCommitted(machineId: String) async -> Bool { true }
    func profileSnapshot() async -> DSHTransportProfileSnapshot? { nil }
}

struct DSHTransportProfileSnapshot: Sendable {
    let profiles: [DSHRemoteProfile]
    let activeProfile: DSHRemoteProfile?
}

private struct DSHRelayUpgradeRequired: LocalizedError {
    var errorDescription: String? { "请先升级 Relay 服务后再使用项目、模式或重命名功能。已有会话仍可正常使用。" }
}

private struct DSHRelayPairingUpgradeRequired: LocalizedError {
    var errorDescription: String? { "当前 Relay 不支持安全配对，请先升级 Relay 服务后再试。" }
}

private enum DSHProvisionalPairingState: String, Codable, Sendable {
    case provisional
    case localCommitted
    /// Relay has already revoked/expired the credential. This state is
    /// persisted before local cleanup so a crash can resume safely.
    case remoteRevoked
}

private struct DSHProvisionalPairingMarker: Codable, Sendable {
    let machineId: String
    let deviceId: String
    let relayBaseURL: URL
    let createdAt: Date
    let provisionalUntil: Date?
    var state: DSHProvisionalPairingState

    init(machineId: String, deviceId: String, relayBaseURL: URL, createdAt: Date,
         provisionalUntil: Date? = nil,
         state: DSHProvisionalPairingState = .provisional) {
        self.machineId = machineId
        self.deviceId = deviceId
        self.relayBaseURL = relayBaseURL
        self.createdAt = createdAt
        self.provisionalUntil = provisionalUntil
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case machineId, deviceId, relayBaseURL, createdAt, provisionalUntil, state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        machineId = try container.decode(String.self, forKey: .machineId)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        relayBaseURL = try container.decode(URL.self, forKey: .relayBaseURL)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        provisionalUntil = try container.decodeIfPresent(Date.self, forKey: .provisionalUntil)
        // Markers written by older builds were all provisional. Treat a
        // missing state conservatively so an upgrade never silently activates
        // a credential whose local commit was not proven durable.
        state = try container.decodeIfPresent(DSHProvisionalPairingState.self, forKey: .state)
            ?? .provisional
    }
}

private struct DSHProvisionalPairing: Sendable {
    let profile: DSHRemoteProfile
    let token: String
    let provisionalUntil: Date?
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
    /// Credentials returned by Relay remain provisional until the app has
    /// committed its local profile and transaction journal. Keep every
    /// provisional device by device id and mirror a marker to UserDefaults so
    /// a process exit cannot silently lose the compensating revoke.
    private var provisionalPairings: [String: DSHProvisionalPairing] = [:]
    private static let provisionalPairingsKey = "dsh-anywhere.provisional-pairings"
    private static let provisionalPairingTTL: TimeInterval = 15 * 60

    func profileSnapshot() async -> DSHTransportProfileSnapshot? {
        DSHTransportProfileSnapshot(profiles: store.profiles, activeProfile: store.activeProfile)
    }

    init(tokenStore: any DSHTokenStore = DSHKeychainTokenStore(),
         store: DSHProfileStore = DSHProfileStore()) {
        self.tokenStore = tokenStore
        self.store = store
    }

    nonisolated static var isConfigured: Bool { !DSHProfileStore().profiles.isEmpty }

    func pair(serverAddress: String, machineId: String, credential: DSHPairingCredential, deviceName: String) async throws -> DSHRemoteProfile {
        await cleanupRemoteRevokedMarkers()
        await expireOrphanedMarkers()
        await cleanupRemoteRevokedMarkers()
        await finalizeCommittedPairingMarkers()
        await drainProvisionalPairings()
        if !loadProvisionalMarkers().isEmpty {
            throw DSHAPIError.http(status: 409, message: "上一笔配对补偿尚未完成，请联网后重试。")
        }
        let baseURL = try DSHAPIClient.relayBaseURL(from: serverAddress)
        try await verifyProvisionalPairingSupport(baseURL)
        let result = try await DSHAPIClient(relayBaseURL: baseURL).pair(
            machineId: machineId, credential: credential, deviceName: deviceName,
            provisional: true
        )
        provisionalPairings[result.profile.deviceId] = DSHProvisionalPairing(
            profile: result.profile, token: result.token, provisionalUntil: result.provisionalUntil)
        // Pairing a second Mac makes the returned profile active. Tear down
        // the old machine socket before committing that profile so no event
        // or command can cross the lifecycle boundary.
        do {
            try tokenStore.save(result.token, account: result.profile.deviceId)
            rememberProvisionalPairing(result.profile, token: result.token,
                                       provisionalUntil: result.provisionalUntil)
            await disconnect()
            // Adds to the machine list rather than replacing it, so pairing a second
            // Mac no longer makes the first one unreachable.
            store.upsert(result.profile)
            return result.profile
        } catch {
            await revokeProvisionalPairing(result.profile.machineId)
            throw error
        }
    }

    func connect() async -> AsyncThrowingStream<DSHEvent, Error> {
        await cleanupRemoteRevokedMarkers()
        await expireOrphanedMarkers()
        await cleanupRemoteRevokedMarkers()
        await finalizeCommittedPairingMarkers()
        await drainProvisionalPairings()
        if !loadProvisionalMarkers().isEmpty {
            return AsyncThrowingStream {
                $0.finish(throwing: DSHAPIError.http(
                    status: 409, message: "上一笔配对补偿尚未完成，请联网后重试。"))
            }
        }
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
        try await send(command, notAfter: nil)
    }

    func send(_ command: DSHCommand, notAfter: Date?) async throws {
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
        try await connection.send(outgoing, notAfter: notAfter)
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
        guard selection == machineSelectionGeneration,
              store.profiles.contains(where: { $0.machineId == machineId }) else {
            if pendingMachineSelectionID == machineId { pendingMachineSelectionID = nil }
            return
        }
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

    func rollbackPairing(machineId: String) async {
        if store.activeMachineId == machineId { await disconnect() }
        // An explicit local rollback is authoritative even if the marker had
        // already been fenced as locally committed. It is used only when a
        // later local journal write failed, so the Relay credential must still
        // be compensated rather than left active.
        await revokeProvisionalPairing(machineId, includeCommitted: true)
        guard let profile = store.profiles.first(where: { $0.machineId == machineId }) else { return }
        try? tokenStore.delete(account: profile.deviceId)
        store.remove(machineId)
    }

    func commitPairing(machineId: String) async {
        _ = await markPairingLocallyCommitted(machineId: machineId)
        await finalizeCommittedPairingMarkers()
    }

    func markPairingLocallyCommitted(machineId: String) async -> Bool {
        var markers = loadProvisionalMarkers()
        let deviceIDs = markers.compactMap { deviceId, marker in
            marker.machineId == machineId && marker.state == .provisional ? deviceId : nil
        }
        guard !deviceIDs.isEmpty else {
            // A missing marker is not safe to treat as committed: the caller
            // may otherwise finish its journal while the Relay credential has
            // no durable lifecycle record at all.
            return markers.values.contains(where: {
                $0.machineId == machineId && $0.state == .localCommitted
            })
        }
        for deviceID in deviceIDs { markers[deviceID]?.state = .localCommitted }
        saveProvisionalMarkers(markers)
        return loadProvisionalMarkers().contains { deviceID, marker in
            deviceIDs.contains(deviceID) && marker.machineId == machineId && marker.state == .localCommitted
        }
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

    private func revokeProvisionalPairing(_ machineId: String, includeCommitted: Bool = false) async {
        var markers = loadProvisionalMarkers()
        let targets = markers.values.filter {
            $0.machineId == machineId &&
                (includeCommitted ? $0.state != .remoteRevoked : $0.state == .provisional)
        }
        for marker in targets {
            let persistedToken = try? tokenStore.read(account: marker.deviceId)
            let provisional = provisionalPairings[marker.deviceId]
                ?? persistedToken.flatMap { token in
                    DSHProvisionalPairing(
                        profile: DSHRemoteProfile(relayBaseURL: marker.relayBaseURL,
                                                   deviceId: marker.deviceId,
                                                   machineId: marker.machineId,
                                                   machineName: ""),
                        token: token, provisionalUntil: marker.provisionalUntil)
                }
            guard let provisional else { continue }
            do {
                try await DSHAPIClient(relayBaseURL: provisional.profile.relayBaseURL)
                    .revokeSelfDevice(machineId: provisional.profile.machineId, token: provisional.token)
                guard markRemoteRevoked(marker, in: &markers) else {
                    provisionalPairings[marker.deviceId] = provisional
                    continue
                }
                try? tokenStore.delete(account: provisional.profile.deviceId)
                store.remove(marker.machineId)
                provisionalPairings.removeValue(forKey: marker.deviceId)
                markers.removeValue(forKey: marker.deviceId)
            } catch {
                // A 401 means the Relay-side provisional TTL has elapsed (or
                // an operator already revoked the token). In either case the
                // credential is no longer usable, so retaining the marker
                // would permanently block a fresh pairing. Network failures
                // remain fail-closed and keep the compensating revoke pending.
                if case DSHAPIError.http(let status, _) = error, status == 401 {
                    guard markRemoteRevoked(marker, in: &markers) else {
                        provisionalPairings[marker.deviceId] = provisional
                        continue
                    }
                    try? tokenStore.delete(account: provisional.profile.deviceId)
                    store.remove(marker.machineId)
                    provisionalPairings.removeValue(forKey: marker.deviceId)
                    markers.removeValue(forKey: marker.deviceId)
                } else {
                    provisionalPairings[marker.deviceId] = provisional
                }
            }
        }
        saveProvisionalMarkers(markers)
    }

    /// A marker is the durable source of truth for a pairing compensation.
    /// Once Relay has confirmed revoke (or its 401 proves the credential is
    /// already unusable), record that fact before deleting local secrets. A
    /// subsequent launch can then finish cleanup without needing the token.
    @discardableResult
    private func markRemoteRevoked(_ marker: DSHProvisionalPairingMarker,
                                   in markers: inout [String: DSHProvisionalPairingMarker]) -> Bool {
        guard var next = markers[marker.deviceId] else { return false }
        next.state = .remoteRevoked
        markers[marker.deviceId] = next
        return saveProvisionalMarkers(markers)
    }

    /// Finishes cleanup that was durably fenced as remoteRevoked before the
    /// process was killed. Every operation is idempotent.
    private func cleanupRemoteRevokedMarkers() async {
        var markers = loadProvisionalMarkers()
        let targets = markers.values.filter { $0.state == .remoteRevoked }
        guard !targets.isEmpty else { return }
        for marker in targets {
            try? tokenStore.delete(account: marker.deviceId)
            store.remove(marker.machineId)
            provisionalPairings.removeValue(forKey: marker.deviceId)
            markers.removeValue(forKey: marker.deviceId)
        }
        saveProvisionalMarkers(markers)
    }

    /// If a crash happened after local token deletion but before the marker
    /// was fenced, no network credential remains to perform compensation. The
    /// Relay provisional deadline is the safe point at which the orphan is
    /// known to be unusable; old markers fall back to the fixed Relay TTL.
    private func expireOrphanedMarkers() async {
        var markers = loadProvisionalMarkers()
        var changed = false
        let now = Date()
        for marker in markers.values where marker.state != .remoteRevoked {
            let hasToken = provisionalPairings[marker.deviceId] != nil ||
                (try? tokenStore.read(account: marker.deviceId)) != nil
            guard !hasToken else { continue }
            let expiry = marker.provisionalUntil
                ?? marker.createdAt.addingTimeInterval(Self.provisionalPairingTTL)
            guard now >= expiry else { continue }
            markers[marker.deviceId]?.state = .remoteRevoked
            changed = true
        }
        if changed { saveProvisionalMarkers(markers) }
    }

    private func verifyProvisionalPairingSupport(_ baseURL: URL) async throws {
        var request = URLRequest(url: baseURL.appending(path: "health"))
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        struct Health: Decodable {
            let schemaRevision: Int?
            let provisionalPairing: Bool?
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let health = try? JSONDecoder().decode(Health.self, from: data),
              health.provisionalPairing == true || (health.schemaRevision ?? 0) >= 10 else {
            throw DSHRelayPairingUpgradeRequired()
        }
    }

    private func drainProvisionalPairings() async {
        let machineIDs = Set(loadProvisionalMarkers().values
            .filter { $0.state == .provisional }
            .map(\.machineId))
        for machineID in machineIDs {
            await revokeProvisionalPairing(machineID)
        }
    }

    /// A locally committed marker is safe to keep across a process exit, but
    /// the Relay still needs the second phase of the pairing handshake. Only
    /// remove the marker after activation succeeds; otherwise connect() fails
    /// closed and retries it on the next launch.
    private func finalizeCommittedPairingMarkers() async {
        var markers = loadProvisionalMarkers()
        let targets = markers.values.filter { $0.state == .localCommitted }
        for marker in targets {
            let persistedToken = try? tokenStore.read(account: marker.deviceId)
            let token = provisionalPairings[marker.deviceId]?.token ?? persistedToken
            guard let token else { continue }
            do {
                try await DSHAPIClient(relayBaseURL: marker.relayBaseURL)
                    .activateSelfDevice(machineId: marker.machineId, token: token)
                provisionalPairings.removeValue(forKey: marker.deviceId)
                markers.removeValue(forKey: marker.deviceId)
            } catch {
                if case DSHAPIError.http(let status, _) = error, status == 401 {
                    // The locally committed profile can no longer authenticate
                    // (expired provisional TTL or external revocation). Drop
                    // this unusable profile and let the UI request pairing
                    // again instead of retrying a dead marker forever.
                    guard markRemoteRevoked(marker, in: &markers) else {
                        provisionalPairings[marker.deviceId] = DSHProvisionalPairing(
                            profile: DSHRemoteProfile(relayBaseURL: marker.relayBaseURL,
                                                      deviceId: marker.deviceId,
                                                      machineId: marker.machineId,
                                                      machineName: ""),
                            token: token, provisionalUntil: marker.provisionalUntil)
                        continue
                    }
                    try? tokenStore.delete(account: marker.deviceId)
                    store.remove(marker.machineId)
                    provisionalPairings.removeValue(forKey: marker.deviceId)
                    markers.removeValue(forKey: marker.deviceId)
                } else {
                    provisionalPairings[marker.deviceId] = DSHProvisionalPairing(
                        profile: DSHRemoteProfile(relayBaseURL: marker.relayBaseURL,
                                                   deviceId: marker.deviceId,
                                                   machineId: marker.machineId,
                                                   machineName: ""),
                        token: token, provisionalUntil: marker.provisionalUntil)
                }
            }
        }
        saveProvisionalMarkers(markers)
    }

    private func loadProvisionalMarkers() -> [String: DSHProvisionalPairingMarker] {
        guard let data = UserDefaults.standard.data(forKey: Self.provisionalPairingsKey),
              let decoded = try? JSONDecoder().decode(
                [String: DSHProvisionalPairingMarker].self, from: data) else { return [:] }
        return decoded
    }

    @discardableResult
    private func saveProvisionalMarkers(_ markers: [String: DSHProvisionalPairingMarker]) -> Bool {
        guard let data = try? JSONEncoder().encode(markers) else { return false }
        UserDefaults.standard.set(data, forKey: Self.provisionalPairingsKey)
        // This marker is the crash-recovery fence for a remote credential.
        // Force the UserDefaults write before deleting the corresponding
        // Keychain token/profile below.
        UserDefaults.standard.synchronize()
        return UserDefaults.standard.data(forKey: Self.provisionalPairingsKey) == data
    }

    private func rememberProvisionalPairing(_ profile: DSHRemoteProfile, token: String,
                                            provisionalUntil: Date?) {
        provisionalPairings[profile.deviceId] = DSHProvisionalPairing(
            profile: profile, token: token, provisionalUntil: provisionalUntil)
        var markers = loadProvisionalMarkers()
        markers[profile.deviceId] = DSHProvisionalPairingMarker(
            machineId: profile.machineId, deviceId: profile.deviceId,
            relayBaseURL: profile.relayBaseURL, createdAt: Date(),
            provisionalUntil: provisionalUntil)
        saveProvisionalMarkers(markers)
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

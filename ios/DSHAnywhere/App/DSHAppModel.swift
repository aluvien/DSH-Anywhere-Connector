import Foundation
import Combine

private enum DSHAttachmentUploadError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut: return "The attachment upload timed out. Please try again."
        }
    }
}

private struct DSHRemoteCommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct DSHPendingInitialMessage {
    let text: String
    let attachments: [DSHStagedAttachment]
}

/// The reasoning choices exposed by the currently selected Harness model.
/// This is derived from the live model catalog rather than a hard-coded list,
/// so the phone follows additions/removals made by the desktop Harness.
struct DSHReasoningConfiguration: Equatable {
    let provider: String
    let model: String
    let efforts: [DSHModelReasoningEffort]
    let selectedEffortID: String

    var selectedEffort: DSHModelReasoningEffort? {
        efforts.first { $0.id == selectedEffortID }
    }
}

/// One shared interpretation of device reachability for every screen.
/// Relay health and Mac presence are intentionally not conflated.
enum DSHDeviceStatus: Equatable {
    case offline
    case error
    case online
    case approvalRequired
}

@MainActor
final class DSHAppModel: ObservableObject {
    @Published private(set) var state: DSHStoreState
    @Published private(set) var isPaired: Bool
    @Published private(set) var isPairing = false
    @Published var machineID = ""
    @Published var pairingSecret = ""
    @Published var serverAddress = UserDefaults.standard.string(forKey: "dsh-anywhere.server-address") ?? ""
    @Published var machineName = "My Mac"
    @Published var selectedSessionID: String?
    @Published var draft = ""
    @Published var showArchivedSessions = false
    /// Conversation presentation choices. These are local UI preferences and
    /// deliberately do not alter the Harness session itself.
    @Published var showUsageFooter: Bool =
        UserDefaults.standard.object(forKey: DSHAppModel.usageFooterKey) as? Bool ?? true
    @Published var showTurnUsage: Bool =
        UserDefaults.standard.object(forKey: DSHAppModel.turnUsageKey) as? Bool ?? false
    /// Message copy/delete controls stay out of the transcript until a user
    /// taps a message. Power users can opt into showing them on every row.
    @Published var showMessageActionsByDefault: Bool =
        UserDefaults.standard.object(forKey: DSHAppModel.messageActionsKey) as? Bool ?? false
    @Published var collapseComposerControls: Bool =
        UserDefaults.standard.object(forKey: DSHAppModel.composerCollapsedKey) as? Bool ?? true
    /// List arrangement and per-section collapse survive relaunch: they are
    /// browsing preferences, not session state.
    /// Happy's phone home is a flat, activity-sorted list.  Keep the old
    /// grouping preference under its legacy key, but start the new UI in flat
    /// mode so an upgrade does not unexpectedly reopen the former project-card
    /// layout.
    @Published var groupsSessionsByWorkspace: Bool =
        UserDefaults.standard.object(forKey: DSHAppModel.groupingKey) as? Bool ?? false
    @Published var collapsedSessionGroups: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: DSHAppModel.collapsedGroupsKey) ?? [])
    @Published private(set) var workspaceAliases: [String: String] =
        (UserDefaults.standard.dictionary(forKey: DSHAppModel.workspaceAliasesKey) as? [String: String]) ?? [:]
    @Published private(set) var hiddenWorkspaceIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: DSHAppModel.hiddenWorkspacesKey) ?? [])
    /// The Harness bridge has no command for deleting one historical message.
    /// Keep a persistent, device-local suppression list so a confirmed delete
    /// does not reappear on refresh while the authoritative Mac transcript is
    /// left untouched.
    @Published private(set) var hiddenMessageKeys: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: DSHAppModel.hiddenMessagesKey) ?? [])
    /// Read markers are local to this phone. The Harness does not currently
    /// expose cross-device read receipts, but persisting the session timestamp
    /// is enough to highlight activity that arrived after the user last opened
    /// that conversation.
    @Published private(set) var lastReadSessionTimestamps: [String: Int64] =
        DSHAppModel.loadLastReadSessionTimestamps()
    /// Interface language. "Follow the device" is the default, and the choice
    /// survives relaunch like the other browsing preferences.
    @Published var language: DSHLanguage =
        DSHLanguage(rawValue: UserDefaults.standard.string(forKey: DSHAppModel.languageKey) ?? "") ?? .system
    @Published var errorMessage: String?
    /// Every Mac this iPhone is paired with, and which one is active.
    @Published private(set) var machines: [DSHRemoteProfile]
    /// Devices paired to the active machine, as the Relay reports them.
    @Published private(set) var pairedDevices: [DSHRelayDevice] = []
    /// Kept apart from `errorMessage` so a device-list failure does not pop an
    /// alert over whatever the user is doing in Settings.
    @Published var devicesError: String?

    private let transport: any DSHAppTransport
    private let reducer = DSHEventReducer()
    private var eventTask: Task<Void, Never>?
    /// WebSocket deltas can arrive much faster than a phone needs to redraw.
    /// Keep the reducer authoritative, but publish one state snapshot per
    /// frame-sized window instead of invalidating every SwiftUI view for every
    /// token. This is what keeps live output responsive without a hot CPU.
    private var pendingEvents: [DSHEvent] = []
    private var eventFlushTask: Task<Void, Never>?
    private static let eventBatchNanoseconds: UInt64 = 50_000_000
    /// A prompt upload completes before the Harness emits its accepted user
    /// message. Queue the local thumbnails so that event can attach them to the
    /// correct transcript row without guessing by message text.
    private var pendingMessageAttachmentsBySession: [String: [[DSHMessageAttachment]]] = [:]
    private var attachmentDataByReceipt: [String: Data] = [:]
    private let deviceID = "ios-device"
    /// The `session.create` request whose reply should open a session, if any.
    private var awaitingCreatedSession: String?
    /// Attachments selected in the shared new-session composer stay local until
    /// the session exists. They are uploaded and sent as one initial prompt
    /// immediately after the matching `session.created` event arrives.
    private var pendingInitialMessagesByRequestID: [String: DSHPendingInitialMessage] = [:]
    private let profiles = DSHProfileStore()
    private let unreadBaseline = DSHAppModel.loadOrCreateUnreadBaseline()
    static let groupingKey = "dsh-anywhere.session-list-grouping"
    static let languageKey = "dsh-anywhere.language"
    static let collapsedGroupsKey = "dsh-anywhere.collapsed-groups"
    static let usageFooterKey = "dsh-anywhere.show-session-usage"
    static let turnUsageKey = "dsh-anywhere.show-turn-usage"
    static let messageActionsKey = "dsh-anywhere.show-message-actions-by-default"
    static let composerCollapsedKey = "dsh-anywhere.collapse-composer-controls"
    static let workspaceAliasesKey = "dsh-anywhere.workspace-aliases"
    static let hiddenWorkspacesKey = "dsh-anywhere.hidden-workspaces"
    static let hiddenMessagesKey = "dsh-anywhere.hidden-messages"
    static let lastReadSessionsKey = "dsh-anywhere.last-read-session-timestamps"
    static let unreadBaselineKey = "dsh-anywhere.unread-baseline"

    init(transport: any DSHAppTransport = DSHRemoteTransport(),
         initialState: DSHStoreState = .init(), isPaired: Bool? = nil) {
        self.transport = transport
        self.state = initialState
        let stored = DSHProfileStore()
        self.machines = stored.profiles
        self.isPaired = isPaired ?? DSHRemoteTransport.isConfigured
        if let active = stored.activeProfile {
            self.machineName = active.machineName
            self.machineID = active.machineId
        }
    }

    /// The Mac the app is currently talking to.
    var activeMachine: DSHRemoteProfile? { profiles.activeProfile }

    var sessions: [DSHSessionSummary] { state.sessions }
    var hasLoadedSessions: Bool { state.hasLoadedSessions }
    var modelCatalog: DSHModelCatalog? { state.modelCatalog }
    var pendingApprovals: [DSHApprovalRequest] { state.pendingApprovals }
    var pendingQuestions: [DSHQuestionRequest] { state.pendingQuestions }
    var connectionState: DSHConnectionState { state.connectionState }

    var deviceStatus: DSHDeviceStatus {
        switch state.transportState {
        case .failed:
            return .error
        case .reconnecting(let attempt) where attempt >= 3:
            return .error
        default:
            break
        }
        guard state.transportState == .connected, state.machineOnline else { return .offline }
        if state.bridgeReachable == false { return .error }
        if state.bridgeReachable == nil { return .offline }
        return pendingApprovals.isEmpty ? .online : .approvalRequired
    }

    func isSessionUnread(_ session: DSHSessionSummary) -> Bool {
        guard session.archived != true, session.updatedAt > 0 else { return false }
        let lastRead = lastReadSessionTimestamps[sessionReadKey(session.id)] ?? unreadBaseline
        return session.updatedAt > lastRead
    }

    func markSessionRead(_ sessionID: String) {
        let sessionTimestamp = sessions.first(where: { $0.id == sessionID })?.updatedAt ?? 0
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let value = max(sessionTimestamp, now)
        let key = sessionReadKey(sessionID)
        guard lastReadSessionTimestamps[key] != value else { return }
        lastReadSessionTimestamps[key] = value
        UserDefaults.standard.set(lastReadSessionTimestamps, forKey: Self.lastReadSessionsKey)
    }

    func messages(for sessionID: String) -> [DSHChatMessage] {
        state.messagesBySession[sessionID, default: []]
    }

    func tools(for sessionID: String) -> [DSHToolActivity] {
        state.toolsBySession[sessionID, default: []]
    }

    /// The transcript in the order things actually happened: messages and tool
    /// calls interleaved by arrival sequence.
    func transcriptEntries(for sessionID: String) -> [DSHTranscriptEntry] {
        messages(for: sessionID)
            .filter { !hiddenMessageKeys.contains(messageKey(sessionID: sessionID, messageID: $0.id)) }
            .transcriptEntries(
            with: tools(for: sessionID),
            commandResults: commandResults(for: sessionID),
            modelChanges: modelChanges(for: sessionID)
        )
    }

    /// Hides one message on this device. Per-message deletion is not currently
    /// exposed by the Connector/Harness protocol, so this intentionally does
    /// not pretend to mutate the Mac's source history.
    func hideMessage(_ messageID: String, in sessionID: String) {
        hiddenMessageKeys.insert(messageKey(sessionID: sessionID, messageID: messageID))
        UserDefaults.standard.set(Array(hiddenMessageKeys), forKey: Self.hiddenMessagesKey)
    }

    private func messageKey(sessionID: String, messageID: String) -> String {
        "\(machineID)\u{001F}\(sessionID)\u{001F}\(messageID)"
    }

    func modelChanges(for sessionID: String) -> [DSHModelChangeNotice] {
        state.modelChangesBySession[sessionID, default: []]
    }


    func turnState(for sessionID: String) -> String {
        state.turnStateBySession[sessionID, default: "idle"]
    }

    func usage(for sessionID: String) -> DSHSessionUsage? {
        state.usageBySession[sessionID] ?? sessions.first(where: { $0.id == sessionID })?.usage
    }

    func permissionMode(for sessionID: String) -> String {
        state.permissionBySession[sessionID]?.mode
            ?? sessions.first(where: { $0.id == sessionID })?.permissionMode
            ?? "workspace-write"
    }

    func commandResults(for sessionID: String) -> [DSHCommandResult] {
        state.commandResultsBySession[sessionID, default: []]
    }

    func attachments(for sessionID: String) -> [DSHUploadedAttachment] {
        state.attachmentsBySession[sessionID, default: []]
    }

    /// Keeps the already-downsampled image available for the current run and
    /// on disk for a later session-history reload. Only the thumbnail bytes are
    /// cached; the original camera-library asset never leaves Photos.
    func cacheAttachmentData(_ data: Data, for receiptId: String) {
        attachmentDataByReceipt[receiptId] = data
        let url = attachmentCacheURL.appendingPathComponent(receiptId.dshAttachmentCacheFileName)
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                          withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
            } catch {
                // A cache miss only removes the thumbnail; the Harness file and
                // the message itself remain intact.
            }
        }
    }

    func attachmentData(for attachment: DSHMessageAttachment) -> Data? {
        let key = attachment.receiptId ?? attachment.id
        if let cached = attachmentDataByReceipt[key] { return cached }
        let url = attachmentCacheURL.appendingPathComponent(key.dshAttachmentCacheFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        attachmentDataByReceipt[key] = data
        return data
    }

    /// Drops a staged upload before the message goes out. The bytes are already
    /// on the Mac, but nothing was sent with them yet, so this only discards the
    /// reference — which is exactly what makes the chip safe to remove.
    func discardAttachment(_ id: String, for sessionID: String) {
        state.attachmentsBySession[sessionID]?.removeAll { $0.id == id }
    }

    func pair() {
        let trimmedMachineID = machineID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = pairingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMachineID.isEmpty else {
            errorMessage = DSHLocalization.string("Enter the machine ID shown by DSH Anywhere Connector.")
            return
        }
        // One field accepts either shape: an 8-character one-time code or the
        // longer pairing secret, distinguished by length.
        guard let credential = DSHPairingCredential.detect(trimmedSecret) else {
            errorMessage = DSHLocalization.string("Enter the pairing code or secret shown by DSH Anywhere Connector.")
            return
        }
        guard !address.isEmpty else {
            errorMessage = "Enter the HTTPS address for your DSH Anywhere gateway."
            return
        }
        isPairing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isPairing = false }
            do {
                let profile = try await self.transport.pair(
                    serverAddress: address, machineId: trimmedMachineID,
                    credential: credential, deviceName: "iPhone"
                )
                UserDefaults.standard.set(address, forKey: "dsh-anywhere.server-address")
                self.machineName = profile.machineName
                self.machineID = profile.machineId
                self.refreshMachines()
                self.isPaired = true
                self.connect()
            } catch { self.errorMessage = error.localizedDescription }
        }
    }

    private func refreshMachines() {
        machines = profiles.profiles
    }

    /// Points the app at another paired Mac. The socket is torn down first
    /// because it carries the previous machine's identity.
    func switchMachine(_ machine: DSHRemoteProfile) {
        guard machine.machineId != activeMachine?.machineId else { return }
        eventTask?.cancel()
        eventTask = nil
        eventFlushTask?.cancel()
        eventFlushTask = nil
        pendingEvents.removeAll(keepingCapacity: false)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.transport.setActiveMachine(machine.machineId)
            self.machineName = machine.machineName
            self.machineID = machine.machineId
            self.state = DSHStoreState()
            self.refreshMachines()
            self.connect()
        }
    }

    func removeMachine(_ machine: DSHRemoteProfile) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.transport.removeMachine(machine.machineId) }
            catch { self.errorMessage = error.localizedDescription }
            self.refreshMachines()
            if let active = self.profiles.activeProfile {
                self.machineName = active.machineName
                self.machineID = active.machineId
            }
            self.isPaired = !self.machines.isEmpty
        }
    }

    /// Loads the device list for the active machine from the Relay. The Relay
    /// refuses this on older builds, so a failure is reported in Settings rather
    /// than treated as a broken app.
    func refreshPairedDevices() {
        guard isPaired else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.pairedDevices = try await self.transport.pairedDevices()
                self.devicesError = nil
            } catch {
                self.pairedDevices = []
                self.devicesError = error.localizedDescription
            }
        }
    }

    func revokeDevice(_ device: DSHRelayDevice) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.transport.revokeDevice(device.deviceId)
                self.refreshPairedDevices()
            } catch {
                self.devicesError = error.localizedDescription
            }
        }
    }

    /// The device id of the phone holding this app, so Settings can label it and
    /// avoid offering a self-revoke the Relay would refuse anyway.
    var currentDeviceId: String? { profiles.activeProfile?.deviceId }

    func connect() {
        guard isPaired, eventTask == nil else { return }
        state.connectionState = .connecting
        state.transportState = .connecting
        state.machineOnline = false
        state.bridgeReachable = nil
        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await transport.connect()
            do {
                for try await event in stream {
                    self.enqueue(event)
                }
            } catch {
                self.flushPendingEvents()
                self.errorMessage = error.localizedDescription
                self.state.transportState = .failed(error.localizedDescription)
                self.state.machineOnline = false
                self.state.bridgeReachable = nil
                self.state.connectionState = .failed(error.localizedDescription)
            }
            self.flushPendingEvents()
            self.eventTask = nil
        }
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        eventFlushTask?.cancel()
        eventFlushTask = nil
        pendingEvents.removeAll(keepingCapacity: false)
        Task { await transport.disconnect() }
        state.transportState = .disconnected
        state.machineOnline = false
        state.bridgeReachable = nil
        state.connectionState = .disconnected
    }

    func forgetPairing() {
        eventTask?.cancel()
        eventTask = nil
        eventFlushTask?.cancel()
        eventFlushTask = nil
        pendingEvents.removeAll(keepingCapacity: false)
        Task { @MainActor [weak self] in
            do { try await self?.transport.forgetPairing() }
            catch { self?.errorMessage = error.localizedDescription }
            self?.state = .init()
            self?.isPaired = false
        }
    }

    /// Workspaces available when starting a session. Apply the local alias
    /// immediately after a rename while the authoritative snapshot is in
    /// flight, so the new-session picker never briefly shows the old title.
    var workspaces: [DSHWorkspaceOption] {
        sessions.workspaceOptions().map { workspace in
            DSHWorkspaceOption(id: workspace.id,
                               name: workspaceAliases[workspace.id] ?? workspace.name)
        }
    }

    /// Starts a session, optionally inside a workspace.
    ///
    /// Choosing a workspace matters because a session created without one does
    /// not appear in the list at all: the list only shows registered
    /// workspaces, so an unfiled session was reachable once and then lost.
    func createSession(in workspace: DSHWorkspaceOption? = nil,
                       title: String = "新会话",
                       workingDirectory: String? = nil,
                       branch: String? = nil,
                       mode: String = "standard",
                       model: DSHModelSelection? = nil,
                       permissionMode: String = "workspace-write",
                       initialPrompt: String? = nil,
                       initialAttachments: [DSHStagedAttachment] = []) {
        let known = Set(sessions.map(\.id))
        // Remember which request asked for this session. The connector echoes it
        // back as the created event's messageId, which is what lets the reply be
        // matched to this tap instead of guessed at.
        let requestId = UUID().uuidString
        awaitingCreatedSession = requestId
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: [String: DSHJSONValue] = ["title": .string(cleanTitle.isEmpty ? "新会话" : cleanTitle)]
        if let workingDirectory {
            let cleanPath = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanPath.isEmpty { payload["workingDirectory"] = .string(cleanPath) }
        }
        if let workspace { payload["workspaceId"] = .string(workspace.id) }
        if !mode.isEmpty { payload["agentPreset"] = .string(mode) }
        if let branch, !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["branch"] = .string(branch.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let model {
            var modelValue: [String: DSHJSONValue] = [
                "provider": .string(model.provider),
                "model": .string(model.model)
            ]
            if let effort = model.reasoningEffort { modelValue["reasoningEffort"] = .string(effort) }
            payload["model"] = .object(modelValue)
        }
        payload["permissionMode"] = .string(permissionMode)
        // `session.create` can carry plain text, but attachments need a
        // session id before they can be uploaded. When the new-session
        // composer contains files, defer the complete prompt until the
        // matching `session.created` event below.
        if initialAttachments.isEmpty, let initialPrompt {
            let trimmedPrompt = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPrompt.isEmpty {
                payload["initialPrompt"] = .string(trimmedPrompt)
            }
        }
        if !initialAttachments.isEmpty {
            pendingInitialMessagesByRequestID[requestId] = DSHPendingInitialMessage(
                text: initialPrompt ?? "", attachments: initialAttachments)
        }
        let command = DSHCommand(requestId: requestId, deviceId: deviceID, machineId: machineID,
                                  type: "session.create",
                                  payload: .object(payload))
        send(command)
        // Fallback for when `session.created` never arrives (dropped event, older
        // connector): re-request the list and open a session we did not know
        // about. Either path makes the tap do something visible.
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard self.awaitingCreatedSession == requestId else { return }
            self.refreshSessions()
            try? await Task.sleep(for: .seconds(1.5))
            guard self.awaitingCreatedSession == requestId else { return }
            self.awaitingCreatedSession = nil
            if let created = self.sessions.first(where: { !known.contains($0.id) }) {
                self.completeCreatedSession(created, requestID: requestId)
            } else {
                self.pendingInitialMessagesByRequestID.removeValue(forKey: requestId)
            }
        }
    }

    func refreshSessions(includeArchived: Bool? = nil) {
        let include = includeArchived ?? showArchivedSessions
        send(DSHCommand.listSessions(deviceId: deviceID, machineId: machineID, includeArchived: include))
    }

    /// Loads the durable transcript for an existing session. Session snapshots
    /// intentionally contain metadata only; opening a conversation asks the
    /// Mac bridge to inspect that session and stream its normalized history.
    func openSession(_ sessionID: String) {
        send(DSHCommand.openSession(deviceId: deviceID, machineId: machineID,
                                    sessionId: sessionID))
    }

    func sendModelCatalog() {
        send(DSHCommand.modelCatalog(deviceId: deviceID, machineId: machineID))
    }

    func setShowArchived(_ value: Bool) {
        showArchivedSessions = value
        refreshSessions(includeArchived: value)
    }

    var sessionGrouping: DSHSessionGrouping {
        groupsSessionsByWorkspace ? .byWorkspace : .flat
    }

    func setLanguage(_ value: DSHLanguage) {
        language = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.languageKey)
        // Plain strings built in helpers resolve immediately; SwiftUI text
        // follows the environment locale the root view sets from `language`.
        DSHLocalization.language = value
    }

    func setGroupsSessionsByWorkspace(_ value: Bool) {
        groupsSessionsByWorkspace = value
        UserDefaults.standard.set(value, forKey: Self.groupingKey)
    }

    func setShowUsageFooter(_ value: Bool) {
        showUsageFooter = value
        UserDefaults.standard.set(value, forKey: Self.usageFooterKey)
    }

    func setShowTurnUsage(_ value: Bool) {
        showTurnUsage = value
        UserDefaults.standard.set(value, forKey: Self.turnUsageKey)
    }

    func setShowMessageActionsByDefault(_ value: Bool) {
        showMessageActionsByDefault = value
        UserDefaults.standard.set(value, forKey: Self.messageActionsKey)
    }

    func setCollapseComposerControls(_ value: Bool) {
        collapseComposerControls = value
        UserDefaults.standard.set(value, forKey: Self.composerCollapsedKey)
    }

    func isGroupCollapsed(_ id: String) -> Bool { collapsedSessionGroups.contains(id) }

    func setGroup(_ id: String, collapsed: Bool) {
        if collapsed { collapsedSessionGroups.insert(id) } else { collapsedSessionGroups.remove(id) }
        UserDefaults.standard.set(Array(collapsedSessionGroups), forKey: Self.collapsedGroupsKey)
    }

    func workspaceDisplayName(for id: String, fallback: String) -> String {
        workspaceAliases[id] ?? fallback
    }

    /// Project mutations are sent to the Harness workspace registry and also
    /// applied optimistically to this device's presentation cache. The local
    /// cache keeps the list responsive while the Relay round-trip refreshes the
    /// authoritative workspace/session snapshot.
    func renameWorkspace(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workspaceAliases[id] = trimmed
        UserDefaults.standard.set(workspaceAliases, forKey: Self.workspaceAliasesKey)
        send(DSHCommand.renameWorkspace(deviceId: deviceID, machineId: machineID,
                                        workspaceId: id, title: trimmed))
    }

    func deleteWorkspace(_ group: DSHSessionGroup) {
        hiddenWorkspaceIDs.insert(group.id)
        UserDefaults.standard.set(Array(hiddenWorkspaceIDs), forKey: Self.hiddenWorkspacesKey)
        send(DSHCommand.deleteWorkspace(deviceId: deviceID, machineId: machineID,
                                        workspaceId: group.id))
    }

    func archive(_ session: DSHSessionSummary, archived: Bool = true) {
        send(DSHCommand.archiveSession(deviceId: deviceID, machineId: machineID,
                                       sessionId: session.id, archived: archived))
    }

    func sendPrompt(_ text: String, to sessionID: String) {
        sendPrompt(text, attachments: [], to: sessionID)
    }

    func sendPrompt(_ text: String, attachments: [String],
                    messageAttachments: [DSHMessageAttachment] = [], to sessionID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if !messageAttachments.isEmpty {
            pendingMessageAttachmentsBySession[sessionID, default: []].append(messageAttachments)
        }
        let parts = attachments.map { DSHJSONValue.object(["type": .string("file"), "receiptId": .string($0)]) }
        send(DSHCommand.sendPrompt(deviceId: deviceID, machineId: machineID,
                                   sessionId: sessionID, text: trimmed, attachments: parts))
    }

    func selectModel(_ selection: DSHModelSelection, for sessionID: String) {
        send(DSHCommand.selectModel(deviceId: deviceID, machineId: machineID,
                                    sessionId: sessionID, provider: selection.provider,
                                    model: selection.model, reasoningEffort: selection.reasoningEffort))
    }

    /// Resolves the session's model against the server-provided catalog. If a
    /// model has no reasoning choices, nil keeps the control out of the UI.
    func reasoningConfiguration(for sessionID: String) -> DSHReasoningConfiguration? {
        guard let catalog = modelCatalog else { return nil }
        let session = sessions.first { $0.id == sessionID }
        let rawModel = session?.model ?? catalog.default.model
        let preferredProvider = session?.provider ?? catalog.default.provider

        let preferredGroup = catalog.groups.first { $0.id == preferredProvider }
        let preferredMatch = preferredGroup.flatMap { group in
            group.models.first(where: { modelMatches($0, rawValue: rawModel) }).map { (group, $0) }
        }
        let match = preferredMatch ?? catalog.groups.lazy.compactMap { group in
            group.models.first(where: { self.modelMatches($0, rawValue: rawModel) }).map { (group, $0) }
        }.first

        guard let (group, item) = match,
              let reasoning = item.reasoning,
              !reasoning.efforts.isEmpty else { return nil }

        let selected = session?.reasoningEffort
            ?? reasoning.defaultEffort
            ?? (rawModel == catalog.default.model ? catalog.default.reasoningEffort : nil)
            ?? reasoning.efforts[0].id
        return DSHReasoningConfiguration(provider: group.id, model: item.id,
                                         efforts: reasoning.efforts,
                                         selectedEffortID: selected)
    }

    private func modelMatches(_ item: DSHModelCatalogModel, rawValue: String) -> Bool {
        rawValue == item.id || rawValue == item.name || rawValue.hasSuffix("/\(item.id)")
    }

    func setPermission(_ mode: String, for sessionID: String) {
        send(DSHCommand.setPermission(deviceId: deviceID, machineId: machineID,
                                      sessionId: sessionID, mode: mode))
    }

    func executeCommand(_ line: String, for sessionID: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(DSHCommand.executeCommand(deviceId: deviceID, machineId: machineID,
                                      sessionId: sessionID, line: trimmed))
    }

    func uploadAttachment(name: String, data: Data, for sessionID: String) {
        send(DSHCommand.uploadAttachment(deviceId: deviceID, machineId: machineID,
                                         sessionId: sessionID, name: name, data: data))
    }

    /// Uploads one staged attachment and waits until the Connector has
    /// returned its receipt. The receipt is the only safe value to put into a
    /// subsequent prompt, so the composer can now defer all network work until
    /// the user taps Send.
    func uploadAttachmentAndWait(name: String, data: Data, for sessionID: String) async throws -> String {
        let requestId = UUID().uuidString
        let command = DSHCommand.uploadAttachment(deviceId: deviceID, machineId: machineID,
                                                   sessionId: sessionID, name: name, data: data,
                                                   requestId: requestId)
        try await transport.send(command)
        // A large camera image may need to cross the phone, Relay, Connector,
        // and the local Harness before the receipt comes back. The old 10
        // second window expired while the Connector was still within its
        // legitimate upload deadline, leaving the user with a false timeout.
        for _ in 0..<3_000 {
            try Task.checkCancellation()
            if let message = state.protocolErrorsByRequestID[requestId] {
                throw DSHRemoteCommandError(message: message)
            }
            if let uploaded = state.attachmentsBySession[sessionID]?.first(where: { $0.requestId == requestId }) {
                return uploaded.receiptId
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DSHAttachmentUploadError.timedOut
    }

    /// Just the model, without its provider prefix: rows and the composer both
    /// ran out of width showing "provider/model" when only the model differs.
    func shortModelName(for sessionID: String) -> String {
        let full = modelDisplayName(for: sessionID)
        let provider = sessions.first(where: { $0.id == sessionID })?.provider
            ?? modelCatalog?.default.provider
            ?? ""
        let model = full.split(separator: "/").last.map(String.init) ?? full
        let lowered = "\(provider)/\(full)".lowercased()
        if lowered.contains("deepseek") {
            if lowered.contains("v4.1") && lowered.contains("flash") { return "DS V4.1F" }
            if lowered.contains("v4.1") && (lowered.contains("reason") || lowered.contains("r1")) { return "DS V4.1R" }
            if lowered.contains("v4.1") { return "DS V4.1" }
            if lowered.contains("v3") { return "DS V3" }
        }
        if lowered.contains("claude") {
            if lowered.contains("opus") { return "Claude Opus" }
            if lowered.contains("sonnet") { return "Claude Sonnet" }
            if lowered.contains("haiku") { return "Claude Haiku" }
        }
        if lowered.contains("gpt-5") { return "GPT-5" }
        if lowered.contains("gpt-4") { return "GPT-4" }
        if lowered.contains("gemini") { return "Gemini" }
        return model
    }

    func modelDisplayName(for sessionID: String) -> String {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return modelCatalog?.default.model ?? "Select model"
        }
        if let model = session.model { return model }
        return modelCatalog?.default.model ?? "Select model"
    }

    /// Human-friendly abbreviations keep the compact composer readable while
    /// the model picker continues to show each provider's full name.
    func modelLabel(for selection: DSHModelSelection, compact: Bool = true) -> String {
        guard compact else { return "\(selection.provider)/\(selection.model)" }
        let raw = selection.model
        let lowered = "\(selection.provider)/\(raw)".lowercased()
        if lowered.contains("deepseek") {
            if lowered.contains("v4.1") && lowered.contains("flash") { return "DS V4.1F" }
            if lowered.contains("v4.1") && lowered.contains("reason") { return "DS V4.1R" }
            if lowered.contains("v4.1") { return "DS V4.1" }
            if lowered.contains("v3") { return "DS V3" }
            return "DeepSeek"
        }
        if lowered.contains("claude") {
            if lowered.contains("opus") { return "Claude Opus" }
            if lowered.contains("sonnet") { return "Claude Sonnet" }
            if lowered.contains("haiku") { return "Claude Haiku" }
        }
        if lowered.contains("gpt-4") { return "GPT-4" }
        if lowered.contains("gpt-5") { return "GPT-5" }
        if lowered.contains("gemini") { return "Gemini" }
        return raw
    }

    func modeLabel(for sessionID: String) -> String {
        let value = sessions.first(where: { $0.id == sessionID })?.mode
            ?? sessions.first(where: { $0.id == sessionID })?.agentPreset
            ?? "standard"
        switch value.lowercased() {
        case "ptc", "plan-to-code", "plan_to_code": return "PTC 模式"
        case "custom", "self", "自建", "自建模式": return "自建模式"
        default: return "标准模式"
        }
    }

    func cancelTurn(for sessionID: String) {
        send(DSHCommand.cancelTurn(deviceId: deviceID, machineId: machineID, sessionId: sessionID))
    }

    func decide(_ approval: DSHApprovalRequest, allow: Bool) {
        send(DSHCommand.decideApproval(deviceId: deviceID, machineId: machineID,
                                       sessionId: approval.sessionId, approvalId: approval.id, allow: allow))
    }

    func answer(_ request: DSHQuestionRequest, answers: [DSHQuestionAnswer]) {
        guard !answers.isEmpty else { return }
        send(DSHCommand.answerQuestion(deviceId: deviceID, machineId: machineID,
                                       sessionId: request.sessionId, questionId: request.id,
                                       answers: answers))
    }

    private func send(_ command: DSHCommand) {
        Task { @MainActor [weak self] in
            do { try await self?.transport.send(command) }
            catch { self?.errorMessage = error.localizedDescription }
        }
    }

    private func enqueue(_ event: DSHEvent) {
        pendingEvents.append(event)
        guard eventFlushTask == nil else { return }
        eventFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.eventBatchNanoseconds)
            guard !Task.isCancelled else { return }
            self?.flushPendingEvents()
        }
    }

    private func flushPendingEvents() {
        eventFlushTask = nil
        guard !pendingEvents.isEmpty else { return }
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)

        // Mutate a local copy and assign once. `state` is @Published, so this
        // turns a burst of assistant deltas/tool events into one UI update.
        var next = state
        for event in events {
            reducer.reduce(event, into: &next)
        }
        attachPendingMessageThumbnails(to: &next, events: events)
        // Do not compare the entire transcript here: that equality check would
        // walk every message/tool on every frame and cost more than the
        // notification we are trying to avoid. A batch always represents one
        // transport tick, so one assignment is the bounded publication point.
        state = next

        for event in events {
            handleSessionCreated(event)
        }
    }

    private func attachPendingMessageThumbnails(to state: inout DSHStoreState,
                                                events: [DSHEvent]) {
        for event in events {
            guard case .userMessageAccepted(let message) = event.kind,
                  let sessionID = event.envelope.sessionId,
                  var queue = pendingMessageAttachmentsBySession[sessionID],
                  !queue.isEmpty,
                  let index = state.messagesBySession[sessionID]?.firstIndex(where: { $0.id == message.id }) else {
                continue
            }
            let local = queue.removeFirst()
            if state.messagesBySession[sessionID]![index].attachments.isEmpty {
                state.messagesBySession[sessionID]![index].attachments = local
            }
            pendingMessageAttachmentsBySession[sessionID] = queue.isEmpty ? nil : queue
        }
    }

    private var attachmentCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DSH Anywhere/attachments", isDirectory: true)
    }

    private func handleSessionCreated(_ event: DSHEvent) {
        guard case .sessionCreated(let session) = event.kind else { return }
        // Open the session only when *this* device asked for it. The previous
        // check was `selectedSessionID == nil`, which had two failure modes: the
        // flag is only cleared by the list view, so if that view was not on
        // screen when a session arrived it stayed set and silently disabled
        // navigation from then on; and the Harness announces every new session,
        // so an unrelated one could steal the screen. Matching the request id
        // removes both.
        guard let expected = awaitingCreatedSession, event.envelope.messageId == expected else { return }
        completeCreatedSession(session, requestID: expected)
    }

    private func completeCreatedSession(_ session: DSHSessionSummary, requestID: String) {
        awaitingCreatedSession = nil
        selectedSessionID = session.id
        guard let pending = pendingInitialMessagesByRequestID.removeValue(forKey: requestID) else { return }
        Task { @MainActor [weak self] in
            await self?.sendInitialMessage(pending, to: session.id)
        }
    }

    private func sendInitialMessage(_ pending: DSHPendingInitialMessage, to sessionID: String) async {
        guard !pending.attachments.isEmpty else { return }
        do {
            var receipts: [String] = []
            var messageAttachments: [DSHMessageAttachment] = []
            receipts.reserveCapacity(pending.attachments.count)
            messageAttachments.reserveCapacity(pending.attachments.count)
            for attachment in pending.attachments {
                let receipt = try await uploadAttachmentAndWait(name: attachment.name,
                                                                 data: attachment.data,
                                                                 for: sessionID)
                receipts.append(receipt)
                let mediaType = attachment.isImage ? "image/jpeg" : nil
                cacheAttachmentData(attachment.data, for: receipt)
                messageAttachments.append(DSHMessageAttachment(id: receipt,
                                                                name: attachment.name,
                                                                mediaType: mediaType,
                                                                receiptId: receipt))
            }
            sendPrompt(pending.text, attachments: receipts,
                       messageAttachments: messageAttachments, to: sessionID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func preview() -> DSHAppModel {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let session = DSHSessionSummary(id: "preview-session", title: "Plan the iOS client",
                                        updatedAt: now,
                                        cwd: "/Users/aluvien/Documents/Develop/App/DSH-ANYWHERE",
                                        workspaceId: "preview-dsh",
                                        workspaceName: "DSH-ANYWHERE", running: true,
                                        provider: "deepseek", model: "deepseek-v4.1-flash",
                                        reasoningEffort: "medium", branch: "main")
        let second = DSHSessionSummary(id: "preview-session-2", title: "Debug attachment upload",
                                       updatedAt: now - 45_000,
                                       cwd: "/Users/aluvien/Documents/Develop/App/DSH-ANYWHERE",
                                       workspaceId: "preview-dsh", workspaceName: "DSH-ANYWHERE",
                                       model: "deepseek-v4.1-flash", branch: "main")
        let third = DSHSessionSummary(id: "preview-session-3", title: "Research relay reconnect",
                                      updatedAt: now - 180_000,
                                      cwd: "/Users/aluvien/Documents/Develop/App/tihu-test",
                                      workspaceId: "preview-lab", workspaceName: "tihu-test",
                                      model: "deepseek-v4.1-flash", branch: "main")
        var state = DSHStoreState()
        state.sessions = [session, second, third]
        state.transportState = .connected
        state.machineOnline = true
        state.bridgeReachable = true
        state.connectionState = .connected
        let efforts = [
            DSHModelReasoningEffort(id: "low", name: "Low"),
            DSHModelReasoningEffort(id: "medium", name: "Medium"),
            DSHModelReasoningEffort(id: "high", name: "High"),
        ]
        state.modelCatalog = DSHModelCatalog(
            default: DSHModelSelection(provider: "deepseek", model: "deepseek-v4.1-flash",
                                       reasoningEffort: "medium"),
            routableProviders: ["deepseek"],
            groups: [DSHModelCatalogGroup(
                id: "deepseek", name: "DeepSeek",
                models: [DSHModelCatalogModel(
                    id: "deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash",
                    reasoning: DSHModelReasoning(efforts: efforts, defaultEffort: "medium")
                )]
            )],
            failures: []
        )
        state.messagesBySession[session.id] = [
            DSHChatMessage(id: "preview-user", role: .user, markdown: "Build a native client for my local Harness."),
            DSHChatMessage(id: "preview-assistant", role: .assistant, markdown: "I can help you plan and implement the native client.")
        ]
        state.toolsBySession[session.id] = [
            DSHToolActivity(id: "preview-tool", name: "read_project", status: "completed", detail: "Read 12 files")
        ]
        let model = DSHAppModel(transport: DSHPreviewTransport(), initialState: state, isPaired: true)
        model.machineName = "macmini"
        model.selectedSessionID = session.id
        return model
    }

    #if DEBUG
    static func previewHome(grouped: Bool = false) -> DSHAppModel {
        let model = preview()
        model.selectedSessionID = nil
        model.groupsSessionsByWorkspace = grouped
        return model
    }

    /// Preview fixture for the same disconnected home state shown by Happy.
    /// It is DEBUG-only so production builds never expose a hidden launch flag.
    static func previewHomeUnreachable() -> DSHAppModel {
        let model = previewHome()
        model.state.sessions = []
        model.state.hasLoadedSessions = true
        model.state.connectionState = .failed("macmini is unreachable")
        model.machineName = "macmini"
        return model
    }
    #endif

    private func sessionReadKey(_ sessionID: String) -> String {
        "\(machineID)\u{001F}\(sessionID)"
    }

    private static func loadLastReadSessionTimestamps() -> [String: Int64] {
        guard let values = UserDefaults.standard.dictionary(forKey: lastReadSessionsKey) else { return [:] }
        return values.compactMapValues { ($0 as? NSNumber)?.int64Value }
    }

    private static func loadOrCreateUnreadBaseline() -> Int64 {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: unreadBaselineKey) as? NSNumber {
            return stored.int64Value
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        defaults.set(now, forKey: unreadBaselineKey)
        return now
    }
}

private extension String {
    /// Receipt ids are opaque, so encode them into a portable filename rather
    /// than using them directly as a path component.
    var dshAttachmentCacheFileName: String {
        Data(utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}

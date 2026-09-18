import Foundation
import Combine
import UserNotifications

private enum DSHAttachmentUploadError: LocalizedError {
    case timedOut
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .timedOut: return "The attachment upload timed out. Please try again."
        case .tooLarge: return "Attachments must be 10 MiB or smaller."
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

/// Per-session traffic light shown as the row dot.
enum DSHSessionDot: Sendable, Equatable {
    case none
    case green
    case yellow
    case red
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
    /// Assistant copy/branch controls are visible by default, matching Remote.
    /// The setting remains available for a quieter transcript; user messages
    /// always use the native long-press copy menu instead of inline controls.
    @Published var showMessageActionsByDefault: Bool =
        UserDefaults.standard.object(forKey: DSHAppModel.messageActionsKey) as? Bool ?? true
    @Published var collapseComposerControls: Bool =
        UserDefaults.standard.object(forKey: DSHAppModel.composerCollapsedKey) as? Bool ?? true
    /// List arrangement and per-section collapse survive relaunch: they are
    /// browsing preferences, not session state.
    /// ChatGPT Remote's task home is organised by project. Keep the preference
    /// under the existing key so an upgrade preserves a deliberate user choice,
    /// while fresh installs open in the project-card layout by default.
    @Published var groupsSessionsByWorkspace: Bool =
        UserDefaults.standard.object(forKey: DSHAppModel.groupingKey) as? Bool ?? true
    @Published var collapsedSessionGroups: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: DSHAppModel.collapsedGroupsKey) ?? [])
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
    /// The folder picker dismisses only after this request receives the Mac's
    /// `workspace.created` acknowledgement. `nil` means no confirmed result.
    @Published private(set) var createdWorkspace: DSHWorkspaceOption?
    @Published private(set) var isCreatingWorkspace = false
    @Published private(set) var isLoadingDirectory = false

    private let transport: any DSHAppTransport
    private let reducer = DSHEventReducer()
    /// Building transcript sections sorts and folds the entire local history.
    /// Live deltas change only one session, but SwiftUI asks several derived
    /// transcript properties during every body pass.  Keep one snapshot per
    /// session until an event for that session arrives, so a 20 Hz stream does
    /// not repeatedly rebuild the same history in a single frame.
    private var transcriptEntriesCache: [String: [DSHTranscriptEntry]] = [:]
    private var transcriptSectionsCache: [String: [DSHTranscriptSection]] = [:]
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
    /// Thumbnail bytes by receipt. NSCache, not a dict: image bytes are the
    /// largest thing the app holds, a dict would grow without bound, and
    /// cache reads happen off the main actor where a dict would race.
    private let attachmentDataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 100
        cache.totalCostLimit = 50 * 1024 * 1024
        return cache
    }()
    /// Disk ceiling for the same thumbnails; enforced oldest-first on write.
    /// Nonisolated: the eviction sweep runs on a detached background task.
    nonisolated static let attachmentDiskBudgetBytes = 200 * 1024 * 1024
    private let deviceID = "ios-device"
    /// Creation acknowledgements are correlated by the Connector request id;
    /// never infer the created session from a later list snapshot.
    private var pendingSessionCreationRequestIDs: Set<String> = []
    private var pendingWorkspaceCreationRequestID: String?
    /// The picker issues one navigation request at a time. Keeping its latest
    /// id prevents a slower parent-folder response from replacing a newer
    /// child-folder listing.
    private var pendingDirectoryRequestID: String?
    private var requestedCatalogsForConnection = false
    /// Attachments selected in the shared new-session composer stay local until
    /// the session exists. They are uploaded and sent as one initial prompt
    /// immediately after the matching `session.created` event arrives.
    private var pendingInitialMessagesByRequestID: [String: DSHPendingInitialMessage] = [:]
    /// Request ids currently awaited by `uploadAttachmentAndWait`. Their
    /// `protocolError`s are consumed by that waiter (see `surfaceProtocolError`)
    /// and must not also pop the global alert.
    private var uploadWaitRequestIDs: Set<String> = []
    /// Last `openSession` per session, to collapse duplicate replays.
    private var lastOpenSessionAt: [String: Date] = [:]
    /// Force-merge tasks for history batches whose closing bracket never
    /// arrives (bridge died mid-stream). Keyed by session id.
    private var historyTimeoutTasks: [String: Task<Void, Never>] = [:]
    /// Already-notified request ids and failed sessions (see notifyForEvent).
    private var notifiedApprovalIDs: Set<String> = []
    private var notifiedQuestionIDs: Set<String> = []
    private var notifiedFailedSessions: Set<String> = []

    /// Drops all in-flight per-machine bookkeeping. History batches belong to
    /// the previous machine's socket, so their timeouts die here too (the
    /// state reset already drops any carried-over rows).
    private func resetTransientRequestState() {
        pendingEvents.removeAll(keepingCapacity: false)
        transcriptEntriesCache.removeAll(keepingCapacity: false)
        transcriptSectionsCache.removeAll(keepingCapacity: false)
        pendingInitialMessagesByRequestID.removeAll(keepingCapacity: false)
        for task in historyTimeoutTasks.values { task.cancel() }
        historyTimeoutTasks.removeAll(keepingCapacity: false)
        lastOpenSessionAt.removeAll(keepingCapacity: false)
        pendingSessionCreationRequestIDs.removeAll(keepingCapacity: false)
        pendingWorkspaceCreationRequestID = nil
        pendingDirectoryRequestID = nil
        isCreatingWorkspace = false
        isLoadingDirectory = false
        requestedCatalogsForConnection = false
        // Queued prompts belong to one machine: swap the in-memory set for
        // the newly active machine's persisted one (disk already holds both).
        queuedPromptsBySession.removeAll(keepingCapacity: false)
        restoreQueuedPrompts()
    }
    private let profiles = DSHProfileStore()
    private let unreadBaseline = DSHAppModel.loadOrCreateUnreadBaseline()
    static let groupingKey = "dsh-anywhere.session-list-grouping"
    static let languageKey = "dsh-anywhere.language"
    static let collapsedGroupsKey = "dsh-anywhere.collapsed-groups"
    static let usageFooterKey = "dsh-anywhere.show-session-usage"
    static let messageActionsKey = "dsh-anywhere.show-message-actions-by-default"
    static let composerCollapsedKey = "dsh-anywhere.collapse-composer-controls"
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
        restoreQueuedPrompts()
    }

    /// The Mac the app is currently talking to.
    var activeMachine: DSHRemoteProfile? { profiles.activeProfile }

    var sessions: [DSHSessionSummary] { state.sessions }
    var hasLoadedSessions: Bool { state.hasLoadedSessions }
    var modelCatalog: DSHModelCatalog? { state.modelCatalog }
    var pendingApprovals: [DSHApprovalRequest] { state.pendingApprovals }
    var pendingQuestions: [DSHQuestionRequest] { state.pendingQuestions }
    var connectionState: DSHConnectionState { state.connectionState }

    /// Per-session traffic light, same hues as the header status dot:
    /// red = turn died on an error, yellow = the Mac is waiting on the
    /// user (approval or questions), green = unread or running activity.
    func sessionDot(for session: DSHSessionSummary) -> DSHSessionDot {
        let turn = turnState(for: session.id).lowercased()
        if turn == "failed" || turn == "error" { return .red }
        if pendingApprovals.contains(where: { $0.sessionId == session.id })
            || pendingQuestions.contains(where: { $0.sessionId == session.id }) {
            return .yellow
        }
        if session.running == true || isSessionUnread(session) { return .green }
        return .none
    }

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
        if let cached = transcriptEntriesCache[sessionID] { return cached }
        let entries = messages(for: sessionID)
            .filter { !hiddenMessageKeys.contains(messageKey(sessionID: sessionID, messageID: $0.id)) }
            .transcriptEntries(
            with: tools(for: sessionID),
            commandResults: commandResults(for: sessionID),
            modelChanges: modelChanges(for: sessionID)
        )
        transcriptEntriesCache[sessionID] = entries
        return entries
    }

    /// Render units: assistant turns with their tool calls folded in.
    func transcriptSections(for sessionID: String) -> [DSHTranscriptSection] {
        if let cached = transcriptSectionsCache[sessionID] { return cached }
        let sections = transcriptEntries(for: sessionID).groupedTurns()
        transcriptSectionsCache[sessionID] = sections
        return sections
    }

    /// Hides one message on this device. Per-message deletion is not currently
    /// exposed by the Connector/Harness protocol, so this intentionally does
    /// not pretend to mutate the Mac's source history.
    func hideMessage(_ messageID: String, in sessionID: String) {
        hiddenMessageKeys.insert(messageKey(sessionID: sessionID, messageID: messageID))
        invalidateTranscriptCaches(for: [sessionID])
        UserDefaults.standard.set(Array(hiddenMessageKeys), forKey: Self.hiddenMessagesKey)
    }

    private func invalidateTranscriptCaches(for sessionIDs: Set<String>) {
        for sessionID in sessionIDs {
            transcriptEntriesCache.removeValue(forKey: sessionID)
            transcriptSectionsCache.removeValue(forKey: sessionID)
        }
    }

    /// Transcript events normally carry their session in the envelope.  The
    /// history brackets also contain it in their payload because they can be
    /// delivered as control messages.  Keep that fallback so completing a
    /// replay can never leave a cached pre-replay transcript on screen.
    private func transcriptSessionIDs(affectedBy events: [DSHEvent]) -> Set<String> {
        var sessionIDs = Set(events.compactMap(\.envelope.sessionId))
        for event in events {
            switch event.kind {
            case .historyStarted(let batch), .historyCompleted(let batch):
                sessionIDs.insert(batch.sessionId)
            default:
                break
            }
        }
        return sessionIDs
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
        attachmentDataCache.setObject(data as NSData, forKey: receiptId as NSString, cost: data.count)
        let url = attachmentCacheURL.appendingPathComponent(receiptId.dshAttachmentCacheFileName)
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                          withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
                Self.evictAttachmentCache(
                    directory: url.deletingLastPathComponent(),
                    keepingBytesUnder: Self.attachmentDiskBudgetBytes)
            } catch {
                // A cache miss only removes the thumbnail; the Harness file and
                // the message itself remain intact.
            }
        }
    }

    /// Deletes oldest-first until the thumbnail directory fits the budget.
    /// Internal (not private) so the eviction order is unit-tested.
    /// Nonisolated: it runs on a detached background task and only touches
    /// its parameters plus FileManager.
    nonisolated static func evictAttachmentCache(directory: URL, keepingBytesUnder budget: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for url in files {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let size = values.fileSize else { continue }
            total += size
            entries.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > budget else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if total <= budget { break }
        }
    }

    func attachmentData(for attachment: DSHMessageAttachment) -> Data? {
        let key = attachment.receiptId ?? attachment.id
        if let cached = attachmentDataCache.object(forKey: key as NSString) { return cached as Data }
        let url = attachmentCacheURL.appendingPathComponent(key.dshAttachmentCacheFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        attachmentDataCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
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
        resetTransientRequestState()
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
        resetTransientRequestState()
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
        resetTransientRequestState()
        Task { @MainActor [weak self] in
            do { try await self?.transport.forgetPairing() }
            catch { self?.errorMessage = error.localizedDescription }
            self?.state = .init()
            self?.isPaired = false
        }
    }

    /// The paired Mac owns the workspace registry. It includes empty projects,
    /// so deriving this from sessions would make a newly-created project vanish
    /// until its first task exists.
    var workspaces: [DSHWorkspaceOption] { state.workspaceCatalog }
    var modes: [DSHModeOption] { state.modeCatalog?.modes ?? [] }
    var defaultModeID: String? { state.modeCatalog?.defaultMode }
    var directoryListing: DSHDirectoryListing? { state.directoryListing }

    /// Starts a session, optionally inside a workspace.
    ///
    func createSession(in workspace: DSHWorkspaceOption? = nil,
                       title: String? = nil,
                       workingDirectory: String? = nil,
                       branch: String? = nil,
                       mode: String = "standard",
                       model: DSHModelSelection? = nil,
                       permissionMode: String = "workspace-write",
                       initialPrompt: String? = nil,
                       initialAttachments: [DSHStagedAttachment] = []) {
        let requestId = UUID().uuidString
        pendingSessionCreationRequestIDs.insert(requestId)
        var payload: [String: DSHJSONValue] = [:]
        if let title {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanTitle.isEmpty { payload["title"] = .string(cleanTitle) }
        }
        // The bridge accepts workspaceId OR cwd, never both: the workspace
        // registry already resolves the directory, so sending both is a 400.
        if workspace == nil, let workingDirectory {
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
    }

    func refreshSessions(includeArchived: Bool? = nil) {
        let include = includeArchived ?? showArchivedSessions
        send(DSHCommand.listSessions(deviceId: deviceID, machineId: machineID, includeArchived: include))
    }

    func requestWorkspaces() {
        send(DSHCommand.workspaceCatalog(deviceId: deviceID, machineId: machineID))
    }

    func requestModes() {
        send(DSHCommand.modeCatalog(deviceId: deviceID, machineId: machineID))
    }

    func listDirectory(at path: String? = nil) {
        let requestId = UUID().uuidString
        pendingDirectoryRequestID = requestId
        isLoadingDirectory = true
        send(DSHCommand.directoryList(deviceId: deviceID, machineId: machineID,
                                      path: path, requestId: requestId))
    }

    func createWorkspace(at path: String, title: String? = nil) {
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPath.isEmpty, !isCreatingWorkspace else { return }
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestId = UUID().uuidString
        createdWorkspace = nil
        isCreatingWorkspace = true
        pendingWorkspaceCreationRequestID = requestId
        send(DSHCommand.createWorkspace(deviceId: deviceID, machineId: machineID,
                                        path: cleanPath,
                                        title: cleanTitle?.isEmpty == false ? cleanTitle : nil,
                                        requestId: requestId))
    }

    /// Loads the durable transcript for an existing session. Session snapshots
    /// intentionally contain metadata only; opening a conversation asks the
    /// Mac bridge to inspect that session and stream its normalized history.
    /// Replays less than two seconds apart are the same user gesture (appear
    /// plus pull-to-refresh): the second stream would only interleave a
    /// duplicate of the first, so it is skipped.
    func openSession(_ sessionID: String) {
        let now = Date()
        if let last = lastOpenSessionAt[sessionID], now.timeIntervalSince(last) < 2 { return }
        lastOpenSessionAt[sessionID] = now
        send(DSHCommand.openSession(deviceId: deviceID, machineId: machineID,
                                    sessionId: sessionID, streaming: true))
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
        workspaces.first(where: { $0.id == id })?.name ?? fallback
    }

    /// Mutations intentionally wait for the Connector's following catalog or
    /// snapshot. Local aliases and hidden-project sets used to make failed
    /// mutations look successful and could outlive the remote truth.
    func renameWorkspace(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(DSHCommand.renameWorkspace(deviceId: deviceID, machineId: machineID,
                                        workspaceId: id, title: trimmed))
    }

    func deleteWorkspace(_ group: DSHSessionGroup) {
        guard !group.isUnfiled, group.id != DSHSessionGroup.flatGroupID else { return }
        send(DSHCommand.deleteWorkspace(deviceId: deviceID, machineId: machineID,
                                        workspaceId: group.id))
    }

    func renameSession(_ session: DSHSessionSummary, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(DSHCommand.renameSession(deviceId: deviceID, machineId: machineID,
                                      sessionId: session.id, title: trimmed))
    }

    func archive(_ session: DSHSessionSummary, archived: Bool = true) {
        send(DSHCommand.archiveSession(deviceId: deviceID, machineId: machineID,
                                       sessionId: session.id, archived: archived))
    }

    func sendPrompt(_ text: String, to sessionID: String) {
        sendPrompt(text, attachments: [], to: sessionID)
    }

    func sendPrompt(_ text: String, attachments: [String],
                    messageAttachments: [DSHMessageAttachment] = [], to sessionID: String,
                    mode: String = "queue", requestId requestedRequestID: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if !messageAttachments.isEmpty {
            pendingMessageAttachmentsBySession[sessionID, default: []].append(messageAttachments)
        }
        let requestId = requestedRequestID ?? UUID().uuidString
        pendingSendsByRequestID[requestId] = DSHPendingSend(
            id: requestId, text: trimmed, receipts: attachments,
            sessionID: sessionID, mode: mode, sentAt: .now)
        armSendAckTimeout(requestId: requestId)
        let parts = attachments.map { DSHJSONValue.object(["type": .string("file"), "receiptId": .string($0)]) }
        send(DSHCommand.sendPrompt(deviceId: deviceID, machineId: machineID,
                                   sessionId: sessionID, text: trimmed, attachments: parts,
                                   mode: mode, requestId: requestId))
    }

    /// An outbound prompt awaiting its accepted user message. If nothing
    /// comes back, the send failed somewhere between this phone and the Mac.
    struct DSHPendingSend: Sendable, Equatable, Identifiable {
        let id: String
        let text: String
        let receipts: [String]
        let sessionID: String
        let mode: String
        let sentAt: Date
    }

    enum DSHSendFailure: Sendable, Equatable {
        /// Never left the phone (socket down at send time or at timeout).
        case local(String)
        /// Left the phone but the Mac never acknowledged (or rejected it).
        case server(String)
    }

    struct DSHFailedSend: Sendable, Equatable, Identifiable {
        let id: String
        let text: String
        let receipts: [String]
        let sessionID: String
        let mode: String
        let failure: DSHSendFailure
    }

    private var pendingSendsByRequestID: [String: DSHPendingSend] = [:]
    @Published var failedSend: DSHFailedSend?
    /// Acceptance window before a send is declared lost. Internal for tests.
    var sendAckTimeout: TimeInterval = 15

    func pendingSendCount(for sessionID: String) -> Int {
        pendingSendsByRequestID.values.filter { $0.sessionID == sessionID }.count
    }

    private func armSendAckTimeout(requestId: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.sendAckTimeout ?? 15))
            self?.timeoutPendingSend(requestId: requestId)
        }
    }

    func timeoutPendingSend(requestId: String) {
        guard let pending = pendingSendsByRequestID[requestId] else { return }
        pendingSendsByRequestID.removeValue(forKey: requestId)
        let failure: DSHSendFailure
        if let detail = state.protocolErrorsByRequestID[requestId], !detail.isEmpty {
            failure = .server(detail)
        } else if connectionState != .connected {
            failure = .local("连接已断开")
        } else {
            failure = .server("Mac 未响应")
        }
        failedSend = DSHFailedSend(id: requestId, text: pending.text,
                                   receipts: pending.receipts,
                                   sessionID: pending.sessionID, mode: pending.mode, failure: failure)
    }

    /// An accepted user message acknowledges the matching send (and heals a
    /// stale failure banner for the same text).
    func confirmPendingSend(text: String, sessionID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let key = pendingSendsByRequestID.values.first(
            where: { $0.sessionID == sessionID && $0.text == trimmed })?.id {
            pendingSendsByRequestID.removeValue(forKey: key)
        }
        if failedSend?.sessionID == sessionID && failedSend?.text == trimmed {
            failedSend = nil
        }
    }

    /// A transport throw means the prompt never left the phone: park it for
    /// retry instead of only flashing an alert, and drop its staged
    /// thumbnails so they cannot attach to a later, unrelated message.
    /// Internal for tests.
    func parkFailedPromptSend(_ command: DSHCommand, error: Error) {
        pendingSendsByRequestID.removeValue(forKey: command.requestId)
        var receipts: [String] = []
        var text = ""
        var sessionID = ""
        var mode = "queue"
        if case .object(let payload) = command.payload {
            if case .string(let value) = payload["text"] { text = value }
            if let sid = command.sessionId { sessionID = sid }
            if case .string(let value) = payload["mode"], !value.isEmpty { mode = value }
            for key in ["attachments", "content"] {
                if let value = payload[key] { receipts += receiptIds(in: value) }
            }
        }
        if !receipts.isEmpty, var queues = pendingMessageAttachmentsBySession[sessionID] {
            queues.removeAll { inner in
                !inner.isEmpty && inner.allSatisfy { receipts.contains($0.receiptId ?? $0.id) }
            }
            pendingMessageAttachmentsBySession[sessionID] = queues
        }
        failedSend = DSHFailedSend(id: command.requestId, text: text, receipts: receipts,
                                   sessionID: sessionID, mode: mode, failure: .local(error.localizedDescription))
    }

    private func receiptIds(in value: DSHJSONValue) -> [String] {
        switch value {
        case .object(let object):
            if case .string(let receipt) = object["receiptId"] { return [receipt] }
            return []
        case .array(let items):
            return items.flatMap { receiptIds(in: $0) }
        default:
            return []
        }
    }

    func retryFailedSend() {
        guard let failed = failedSend else { return }
        failedSend = nil
        // A timeout means the Mac may already have accepted the side effect.
        // Reuse the complete original command identity and mode so Connector
        // and Bridge idempotency coalesce the retry instead of executing it
        // a second time (a genuinely new submission still gets a new UUID).
        sendPrompt(failed.text, attachments: failed.receipts, to: failed.sessionID,
                   mode: failed.mode, requestId: failed.id)
    }

    func dismissFailedSend() {
        failedSend = nil
    }

    /// A prompt this device queued while its session was busy. Text-only
    /// holds stay on the device (editable/cancellable, auto-sent when the
    /// turn settles); attachment sends go to the server queue immediately and
    /// are only mirrored here for the bubble. Entries retire when accepted.
    struct DSHQueuedPrompt: Sendable, Equatable, Identifiable, Codable {
        let id: String
        var text: String
        let mode: String
        let sentAt: Date
        /// False = held locally (editable, cancellable, sendable). True =
        /// already sent to the server queue (bubble mirror only).
        let sent: Bool

        init(id: String = UUID().uuidString, text: String, mode: String,
             sentAt: Date = .now, sent: Bool = false) {
            self.id = id; self.text = text; self.mode = mode
            self.sentAt = sentAt; self.sent = sent
        }
    }

    private var queuedPromptsBySession: [String: [DSHQueuedPrompt]] = [:]
    private static let queuedPromptTTL: TimeInterval = 24 * 60 * 60
    private static let queuedPromptsDefaultsKey = "dsh-anywhere.queued-prompts"

    private var queuedPromptsDefaultsKey: String {
        "\(Self.queuedPromptsDefaultsKey).\(machineID)"
    }

    /// Holds a text prompt locally until the turn settles (cancellable).
    func holdQueuedPrompt(text: String, for sessionID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queuedPromptsBySession[sessionID, default: []].append(
            DSHQueuedPrompt(text: String(trimmed.prefix(2000)), mode: "queue"))
        persistQueuedPrompts()
    }

    /// Mirrors an attachment send that went straight to the server queue.
    func noteQueuedPrompt(text: String, mode: String, for sessionID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queuedPromptsBySession[sessionID, default: []].append(
            DSHQueuedPrompt(text: String(trimmed.prefix(500)), mode: mode, sent: true))
        persistQueuedPrompts()
    }

    func queuedPrompts(for sessionID: String) -> [DSHQueuedPrompt] {
        let cutoff = Date.now.addingTimeInterval(-Self.queuedPromptTTL)
        let fresh = queuedPromptsBySession[sessionID, default: []].filter { $0.sentAt > cutoff }
        if fresh.count != queuedPromptsBySession[sessionID]?.count {
            queuedPromptsBySession[sessionID] = fresh
            persistQueuedPrompts()
        }
        return fresh
    }

    func updateQueuedPrompt(id: String, text: String, sessionID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var queue = queuedPromptsBySession[sessionID],
              let index = queue.firstIndex(where: { $0.id == id && !$0.sent }) else { return }
        queue[index].text = String(trimmed.prefix(2000))
        queuedPromptsBySession[sessionID] = queue
        persistQueuedPrompts()
    }

    /// Drops a locally held prompt before it ever fires. Server-sent entries
    /// cannot be retracted (no queue API) and are refused here.
    @discardableResult
    func cancelQueuedPrompt(id: String, sessionID: String) -> Bool {
        guard var queue = queuedPromptsBySession[sessionID],
              let index = queue.firstIndex(where: { $0.id == id && !$0.sent }) else { return false }
        queue.remove(at: index)
        queuedPromptsBySession[sessionID] = queue
        persistQueuedPrompts()
        return true
    }

    /// Pops the oldest locally held prompt for immediate sending.
    func takeQueuedPrompt(id: String, sessionID: String) -> DSHQueuedPrompt? {
        guard var queue = queuedPromptsBySession[sessionID],
              let index = queue.firstIndex(where: { $0.id == id && !$0.sent }) else { return nil }
        let item = queue.remove(at: index)
        queuedPromptsBySession[sessionID] = queue
        persistQueuedPrompts()
        return item
    }

    /// Fires the oldest held prompt when a turn settles. Returns false when
    /// there is nothing to fire (or the session is gone).
    @discardableResult
    private func flushQueuedPrompt(for sessionID: String) -> Bool {
        guard var queue = queuedPromptsBySession[sessionID],
              let index = queue.firstIndex(where: { !$0.sent }) else { return false }
        let item = queue.remove(at: index)
        queuedPromptsBySession[sessionID] = queue
        persistQueuedPrompts()
        sendPrompt(item.text, to: sessionID)
        return true
    }

    private func persistQueuedPrompts() {
        guard let data = try? JSONEncoder().encode(queuedPromptsBySession) else { return }
        UserDefaults.standard.set(data, forKey: queuedPromptsDefaultsKey)
    }

    func restoreQueuedPrompts() {
        guard let data = UserDefaults.standard.data(forKey: queuedPromptsDefaultsKey),
              let restored = try? JSONDecoder().decode([String: [DSHQueuedPrompt]].self, from: data)
        else { return }
        let cutoff = Date.now.addingTimeInterval(-Self.queuedPromptTTL)
        queuedPromptsBySession = restored.mapValues { $0.filter { $0.sentAt > cutoff } }
    }

    /// Retires the oldest queued entry whose text matches an accepted user
    /// message (the queued prompt surfacing for its turn).
    func matchQueuedPrompt(text: String, sessionID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var queue = queuedPromptsBySession[sessionID],
              let index = queue.firstIndex(where: { $0.text == trimmed }) else { return }
        queue.remove(at: index)
        queuedPromptsBySession[sessionID] = queue
        persistQueuedPrompts()
    }

    /// A queued prompt surfacing for its turn arrives as an accepted user
    /// message: retire the matching bubble entry.
    private func retireQueuedPrompt(_ event: DSHEvent) {
        guard case .userMessageAccepted(let message) = event.kind,
              let sessionId = event.envelope.sessionId else { return }
        matchQueuedPrompt(text: message.markdown, sessionID: sessionId)
    }

    /// An accepted user message is the send acknowledgment: the matching
    /// outbound prompt made it to the Mac.
    private func confirmSendAccepted(_ event: DSHEvent) {
        guard case .userMessageAccepted(let message) = event.kind,
              let sessionId = event.envelope.sessionId else { return }
        confirmPendingSend(text: message.markdown, sessionID: sessionId)
    }

    /// When a turn settles, fire the oldest locally held prompt (FIFO — the
    /// rest follow as their turns end). Only locally held prompts; the turn
    /// that just ended already consumed the wire.
    private func flushQueueOnSettle(_ event: DSHEvent) {
        guard case .turnStateChanged(let turn) = event.kind else { return }
        switch turn.state.lowercased() {
        case "completed", "failed", "cancelled":
            flushQueuedPrompt(for: turn.sessionId)
        default:
            break
        }
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
        guard data.count <= 10 * 1024 * 1024 else { throw DSHAttachmentUploadError.tooLarge }
        let requestId = UUID().uuidString
        uploadWaitRequestIDs.insert(requestId)
        defer { uploadWaitRequestIDs.remove(requestId) }
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
        guard let value = sessions.first(where: { $0.id == sessionID })?.mode
            ?? sessions.first(where: { $0.id == sessionID })?.agentPreset else {
            return modes.first(where: { $0.id == defaultModeID })?.name ?? "标准模式"
        }
        if let remoteName = modes.first(where: { $0.id == value })?.name { return remoteName }
        switch value.lowercased() {
        case "ptc", "plan-to-code", "plan_to_code": return "PTC 模式"
        case "custom", "self", "自建", "自建模式": return "自建模式"
        case "standard": return "标准模式"
        default: return value
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
            catch {
                guard let self else { return }
                self.clearFailedRemoteRequest(command.requestId)
                // A prompt that never left the phone parks for retry (with
                // its text intact) instead of only flashing an alert while
                // the draft is already gone.
                if command.type == "prompt.send" {
                    self.parkFailedPromptSend(command, error: error)
                } else {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// A local transport rejection (offline socket or an older Relay schema)
    /// has no protocol.error envelope. Clear only the request state owned by
    /// that command so folder-picker controls never remain disabled forever.
    private func clearFailedRemoteRequest(_ requestID: String) {
        if requestID == pendingWorkspaceCreationRequestID {
            pendingWorkspaceCreationRequestID = nil
            isCreatingWorkspace = false
        }
        if requestID == pendingDirectoryRequestID {
            pendingDirectoryRequestID = nil
            isLoadingDirectory = false
        }
        if pendingSessionCreationRequestIDs.remove(requestID) != nil {
            pendingInitialMessagesByRequestID.removeValue(forKey: requestID)
        }
    }

    /// Directory listings are request/response data, never broadcast state.
    /// Ignore an old or another device's reply before it reaches the reducer;
    /// otherwise a late response can visibly jump the folder browser back.
    private func shouldReduce(_ event: DSHEvent) -> Bool {
        guard case .directoryListing = event.kind else { return true }
        return event.envelope.messageId == pendingDirectoryRequestID
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
        let acceptedEvents = events.filter(shouldReduce)
        var next = state
        for event in acceptedEvents {
            reducer.reduce(event, into: &next)
        }
        attachPendingMessageThumbnails(to: &next, events: acceptedEvents)
        invalidateTranscriptCaches(for: transcriptSessionIDs(affectedBy: acceptedEvents))
        // Do not compare the entire transcript here: that equality check would
        // walk every message/tool on every frame and cost more than the
        // notification we are trying to avoid. A batch always represents one
        // transport tick, so one assignment is the bounded publication point.
        state = next

        for event in acceptedEvents {
            handleSessionCreated(event)
            handleRemoteRequestCompletion(event)
            requestRemoteCatalogsWhenConnected(event)
            retireQueuedPrompt(event)
            confirmSendAccepted(event)
            flushQueueOnSettle(event)
            surfaceProtocolError(event)
            trackHistoryBatch(event)
            notifyForEvent(event)
        }
    }

    /// Mirrors the yellow/red session dots in Notification Center: the Mac is
    /// waiting on the user (approval, questions) or a turn died on an error.
    /// Each request notifies once; a session re-arms its failure notice when
    /// it leaves the failed state, so the next failure pings again.
    private func notifyForEvent(_ event: DSHEvent) {
        switch event.kind {
        case .approvalRequested(let approval):
            guard notifiedApprovalIDs.insert(approval.id).inserted else { return }
            let sessionTitle = sessions.first(where: { $0.id == approval.sessionId })?.title
            postLocalNotification(
                title: approvalNotificationTitle(sessionTitle: sessionTitle),
                body: "\(approval.toolName)：\(approval.reason)"
            )
        case .questionAsked(let request):
            guard notifiedQuestionIDs.insert(request.id).inserted else { return }
            let first = request.questions.first?.question ?? ""
            postLocalNotification(title: "需要你回答问题", body: String(first.prefix(120)))
        case .turnStateChanged(let turn):
            let failed = turn.state.lowercased() == "failed" || turn.state.lowercased() == "error"
            if failed {
                guard !notifiedFailedSessions.contains(turn.sessionId) else { return }
                notifiedFailedSessions.insert(turn.sessionId)
                let sessionTitle = sessions.first(where: { $0.id == turn.sessionId })?.title
                postLocalNotification(
                    title: "任务执行中断",
                    body: sessionTitle?.isEmpty == false ? (sessionTitle ?? "") : turn.sessionId
                )
            } else {
                notifiedFailedSessions.remove(turn.sessionId)
            }
        default:
            break
        }
    }

    private func approvalNotificationTitle(sessionTitle: String?) -> String {
        if let sessionTitle, !sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "“\(sessionTitle)”需要权限确认"
        }
        return "需要权限确认"
    }

    /// Local notifications need no Info.plist key; the system prompts on
    /// first use. Silent when denied — the in-app dots remain the fallback.
    private func postLocalNotification(title: String, body: String) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .authorized, .provisional, .ephemeral:
                    self.scheduleLocalNotification(title: title, body: body)
                case .notDetermined:
                    do {
                        let granted = try await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound])
                        if granted {
                            self.scheduleLocalNotification(title: title, body: body)
                        }
                    } catch {
                        // Denied or failed: stay silent, dots cover it.
                    }
                default:
                    break
                }
            }
        }
    }

    private func scheduleLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        ))
    }

    /// Arms (or disarms) the force-merge fallback for one history batch. If
    /// `history.completed` never arrives, the carry entry would linger; after
    /// ten seconds it is merged back (normally a no-op, since rows are never
    /// cleared for replays) and the entry is dropped.
    private func trackHistoryBatch(_ event: DSHEvent) {
        switch event.kind {
        case .historyStarted(let batch):
            historyTimeoutTasks[batch.sessionId]?.cancel()
            historyTimeoutTasks[batch.sessionId] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                guard let self, self.state.historyCarryOverBySession[batch.sessionId] != nil else { return }
                var next = self.state
                self.reducer.completeHistory(sessionId: batch.sessionId, batchId: nil, into: &next)
                self.invalidateTranscriptCaches(for: [batch.sessionId])
                self.state = next
                self.historyTimeoutTasks.removeValue(forKey: batch.sessionId)
            }
        case .historyCompleted(let batch):
            historyTimeoutTasks[batch.sessionId]?.cancel()
            historyTimeoutTasks.removeValue(forKey: batch.sessionId)
        default:
            break
        }
    }

    /// Fire-and-forget commands (`selectModel`, `setPermission`, `sendPrompt`,
    /// …) have no per-call waiter, so a Harness rejection used to sit unread
    /// in `protocolErrorsByRequestID` while the UI acted as if the tap had
    /// worked. Surface each one through the shared error alert instead.
    /// Attachment uploads are excluded: their waiter already reports the same
    /// error next to the composer, and double-reporting would just overwrite it.
    private func surfaceProtocolError(_ event: DSHEvent) {
        guard case .protocolError(let error) = event.kind else { return }
        guard !uploadWaitRequestIDs.contains(event.envelope.messageId) else { return }
        errorMessage = error.message
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
        let requestID = event.envelope.messageId
        guard pendingSessionCreationRequestIDs.contains(requestID) else { return }
        completeCreatedSession(session, requestID: requestID)
    }

    private func completeCreatedSession(_ session: DSHSessionSummary, requestID: String) {
        pendingSessionCreationRequestIDs.remove(requestID)
        selectedSessionID = session.id
        guard let pending = pendingInitialMessagesByRequestID.removeValue(forKey: requestID) else { return }
        Task { @MainActor [weak self] in
            await self?.sendInitialMessage(pending, to: session.id)
        }
    }

    /// Only a correlated remote acknowledgement changes picker completion
    /// state. This prevents a workspace created on another device from
    /// dismissing the local folder picker, and clears spinners on errors.
    private func handleRemoteRequestCompletion(_ event: DSHEvent) {
        let requestID = event.envelope.messageId
        switch event.kind {
        case .workspaceCreated(let workspace)
            where requestID == pendingWorkspaceCreationRequestID:
            pendingWorkspaceCreationRequestID = nil
            isCreatingWorkspace = false
            createdWorkspace = workspace
            requestWorkspaces()
        case .directoryListing where requestID == pendingDirectoryRequestID:
            pendingDirectoryRequestID = nil
            isLoadingDirectory = false
        case .protocolError(let error):
            if requestID == pendingWorkspaceCreationRequestID {
                pendingWorkspaceCreationRequestID = nil
                isCreatingWorkspace = false
                errorMessage = error.message
            }
            if requestID == pendingDirectoryRequestID {
                pendingDirectoryRequestID = nil
                isLoadingDirectory = false
                errorMessage = error.message
            }
            if pendingSessionCreationRequestIDs.remove(requestID) != nil {
                pendingInitialMessagesByRequestID.removeValue(forKey: requestID)
                errorMessage = error.message
            }
        default:
            break
        }
    }

    /// The home view may appear before its socket handshake completes. Ask for
    /// the server-owned workspace and mode catalogs at the actual connection
    /// boundary as well, so empty projects do not depend on a SwiftUI timing
    /// race. The transport's schema gate keeps this harmless on older Relays.
    private func requestRemoteCatalogsWhenConnected(_ event: DSHEvent) {
        guard case .transportState(.connected) = event.kind,
              !requestedCatalogsForConnection else { return }
        requestedCatalogsForConnection = true
        requestWorkspaces()
        requestModes()
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

    static func preview(longConversation: Bool = false) -> DSHAppModel {
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
        // The remote catalog intentionally has a project with no sessions;
        // previews exercise the same source of truth as the production home.
        state.workspaceCatalog = [
            DSHWorkspaceOption(id: "preview-dsh", name: "DSH-ANYWHERE",
                               path: "/Users/aluvien/Documents/Develop/App/DSH-ANYWHERE"),
            DSHWorkspaceOption(id: "preview-lab", name: "tihu-test",
                               path: "/Users/aluvien/Documents/Develop/App/tihu-test"),
            DSHWorkspaceOption(id: "preview-empty", name: "未开始项目",
                               path: "/Users/aluvien/Documents/Develop/App/empty-project"),
        ]
        state.modeCatalog = DSHModeCatalog(defaultMode: "standard", modes: [
            DSHModeOption(id: "standard", name: "标准模式", description: "通用任务执行"),
            DSHModeOption(id: "plan", name: "规划模式", description: "先制定方案再执行"),
            DSHModeOption(id: "review", name: "审查模式", description: "检查已有工作"),
        ])
        state.hasLoadedSessions = true
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
        #if DEBUG
        if longConversation || ProcessInfo.processInfo.arguments.contains("--dsh-preview-long-conversation") {
            state.messagesBySession[session.id] = (0..<12).flatMap { index in
                [DSHChatMessage(id: "user-\(index)", role: .user, markdown: "第 \(index + 1) 轮：测试长对话布局"),
                 DSHChatMessage(id: "assistant-\(index)", role: .assistant,
                                markdown: "第 \(index + 1) 轮回答。\n\n打开输入框后，这段文字应随可见区域抬起。\n\n最后一行必须完整显示在输入框上方。")]
            }
        }
        #endif
        state.toolsBySession[session.id] = [
            DSHToolActivity(id: "preview-tool", name: "read_project", status: "completed", detail: "Read 12 files")
        ]
        let model = DSHAppModel(transport: DSHPreviewTransport(), initialState: state, isPaired: true)
        model.machineName = "macmini"
        model.selectedSessionID = session.id
        model.showMessageActionsByDefault = true
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

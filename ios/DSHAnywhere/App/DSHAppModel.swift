import Foundation
import Combine

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
    /// List arrangement and per-section collapse survive relaunch: they are
    /// browsing preferences, not session state.
    @Published var groupsSessionsByWorkspace: Bool =
        UserDefaults.standard.object(forKey: DSHAppModel.groupingKey) as? Bool ?? true
    @Published var collapsedSessionGroups: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: DSHAppModel.collapsedGroupsKey) ?? [])
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
    private let deviceID = "ios-device"
    /// The `session.create` request whose reply should open a session, if any.
    private var awaitingCreatedSession: String?
    private let profiles = DSHProfileStore()
    static let groupingKey = "dsh-anywhere.group-by-workspace"
    static let collapsedGroupsKey = "dsh-anywhere.collapsed-groups"

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
    var modelCatalog: DSHModelCatalog? { state.modelCatalog }
    var pendingApprovals: [DSHApprovalRequest] { state.pendingApprovals }
    var pendingQuestions: [DSHQuestionRequest] { state.pendingQuestions }
    var connectionState: DSHConnectionState { state.connectionState }

    func messages(for sessionID: String) -> [DSHChatMessage] {
        state.messagesBySession[sessionID, default: []]
    }

    func tools(for sessionID: String) -> [DSHToolActivity] {
        state.toolsBySession[sessionID, default: []]
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

    func pair() {
        let trimmedMachineID = machineID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = pairingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMachineID.isEmpty else {
            errorMessage = "Enter the machine ID shown by DSH Anywhere Connector."
            return
        }
        // One field accepts either shape: an 8-character one-time code or the
        // longer pairing secret, distinguished by length.
        guard let credential = DSHPairingCredential.detect(trimmedSecret) else {
            errorMessage = "Enter the pairing code or secret shown by DSH Anywhere Connector."
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
        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await transport.connect()
            do {
                for try await event in stream {
                    self.reduce(event)
                }
            } catch {
                self.errorMessage = error.localizedDescription
                self.state.connectionState = .failed(error.localizedDescription)
            }
            self.eventTask = nil
        }
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        Task { await transport.disconnect() }
        state.connectionState = .disconnected
    }

    func forgetPairing() {
        eventTask?.cancel()
        eventTask = nil
        Task { @MainActor [weak self] in
            do { try await self?.transport.forgetPairing() }
            catch { self?.errorMessage = error.localizedDescription }
            self?.state = .init()
            self?.isPaired = false
        }
    }

    func createSession() {
        let known = Set(sessions.map(\.id))
        // Remember which request asked for this session. The connector echoes it
        // back as the created event's messageId, which is what lets the reply be
        // matched to this tap instead of guessed at.
        let requestId = UUID().uuidString
        awaitingCreatedSession = requestId
        let command = DSHCommand(requestId: requestId, deviceId: deviceID, machineId: machineID,
                                  type: "session.create",
                                  payload: .object(["title": .string("New session")]))
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
                self.selectedSessionID = created.id
            }
        }
    }

    func refreshSessions(includeArchived: Bool? = nil) {
        let include = includeArchived ?? showArchivedSessions
        send(DSHCommand.listSessions(deviceId: deviceID, machineId: machineID, includeArchived: include))
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

    func setGroupsSessionsByWorkspace(_ value: Bool) {
        groupsSessionsByWorkspace = value
        UserDefaults.standard.set(value, forKey: Self.groupingKey)
    }

    func isGroupCollapsed(_ id: String) -> Bool { collapsedSessionGroups.contains(id) }

    func setGroup(_ id: String, collapsed: Bool) {
        if collapsed { collapsedSessionGroups.insert(id) } else { collapsedSessionGroups.remove(id) }
        UserDefaults.standard.set(Array(collapsedSessionGroups), forKey: Self.collapsedGroupsKey)
    }

    func archive(_ session: DSHSessionSummary, archived: Bool = true) {
        send(DSHCommand.archiveSession(deviceId: deviceID, machineId: machineID,
                                       sessionId: session.id, archived: archived))
    }

    func sendPrompt(_ text: String, to sessionID: String) {
        sendPrompt(text, attachments: [], to: sessionID)
    }

    func sendPrompt(_ text: String, attachments: [String], to sessionID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let parts = attachments.map { DSHJSONValue.object(["type": .string("file"), "receiptId": .string($0)]) }
        send(DSHCommand.sendPrompt(deviceId: deviceID, machineId: machineID,
                                   sessionId: sessionID, text: trimmed, attachments: parts))
    }

    func selectModel(_ selection: DSHModelSelection, for sessionID: String) {
        send(DSHCommand.selectModel(deviceId: deviceID, machineId: machineID,
                                    sessionId: sessionID, provider: selection.provider,
                                    model: selection.model, reasoningEffort: selection.reasoningEffort))
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

    /// Just the model, without its provider prefix: rows and the composer both
    /// ran out of width showing "provider/model" when only the model differs.
    func shortModelName(for sessionID: String) -> String {
        let full = modelDisplayName(for: sessionID)
        return full.split(separator: "/").last.map(String.init) ?? full
    }

    func modelDisplayName(for sessionID: String) -> String {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return modelCatalog?.default.model ?? "Select model"
        }
        if let model = session.model { return model }
        return modelCatalog?.default.model ?? "Select model"
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

    private func reduce(_ event: DSHEvent) {
        reducer.reduce(event, into: &state)
        guard case .sessionCreated(let session) = event.kind else { return }
        // Open the session only when *this* device asked for it. The previous
        // check was `selectedSessionID == nil`, which had two failure modes: the
        // flag is only cleared by the list view, so if that view was not on
        // screen when a session arrived it stayed set and silently disabled
        // navigation from then on; and the Harness announces every new session,
        // so an unrelated one could steal the screen. Matching the request id
        // removes both.
        guard let expected = awaitingCreatedSession, event.envelope.messageId == expected else { return }
        awaitingCreatedSession = nil
        selectedSessionID = session.id
    }

    static func preview() -> DSHAppModel {
        let session = DSHSessionSummary(id: "preview-session", title: "Plan the iOS client",
                                        updatedAt: Int64(Date().timeIntervalSince1970 * 1_000))
        var state = DSHStoreState()
        state.sessions = [session]
        state.connectionState = .connected
        state.messagesBySession[session.id] = [
            DSHChatMessage(id: "preview-user", role: .user, markdown: "Build a native client for my local Harness."),
            DSHChatMessage(id: "preview-assistant", role: .assistant, markdown: "I can help you plan and implement the native client.")
        ]
        state.toolsBySession[session.id] = [
            DSHToolActivity(id: "preview-tool", name: "read_project", status: "completed", detail: "Read 12 files")
        ]
        let model = DSHAppModel(transport: DSHPreviewTransport(), initialState: state, isPaired: true)
        model.selectedSessionID = session.id
        return model
    }
}

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
    @Published var errorMessage: String?

    private let transport: any DSHAppTransport
    private let reducer = DSHEventReducer()
    private var eventTask: Task<Void, Never>?
    private let deviceID = "ios-device"

    init(transport: any DSHAppTransport = DSHRemoteTransport(),
         initialState: DSHStoreState = .init(), isPaired: Bool? = nil) {
        self.transport = transport
        self.state = initialState
        self.isPaired = isPaired ?? DSHRemoteTransport.isConfigured
    }

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
        guard trimmedSecret.count >= 32 else {
            errorMessage = "Enter the pairing secret shown by DSH Anywhere Connector."
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
                    pairingSecret: trimmedSecret, deviceName: "iPhone"
                )
                UserDefaults.standard.set(address, forKey: "dsh-anywhere.server-address")
                self.machineName = profile.machineName
                self.isPaired = true
                self.connect()
            } catch { self.errorMessage = error.localizedDescription }
        }
    }

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
        let command = DSHCommand(version: 1, deviceId: deviceID, machineId: machineID,
                                  type: "session.create",
                                  payload: .object(["title": .string("New session")]))
        send(command)
        // `session.created` is what normally opens the new session. This is the
        // fallback for when that event is dropped: re-request the list, and if a
        // session we did not know about appeared, open it. Either path makes the
        // tap do something visible instead of silently having no effect.
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1))
            guard self.selectedSessionID == nil else { return }
            self.refreshSessions()
            try? await Task.sleep(for: .seconds(1))
            guard self.selectedSessionID == nil else { return }
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
        if case .sessionCreated(let session) = event.kind, selectedSessionID == nil {
            selectedSessionID = session.id
        }
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

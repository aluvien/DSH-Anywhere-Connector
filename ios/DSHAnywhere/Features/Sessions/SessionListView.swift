import SwiftUI

struct SessionListView: View {
    @EnvironmentObject private var model: DSHAppModel
    @State private var navigationPath: [String] = []
    @State private var didRefresh = false
    @State private var collapsedGroups: Set<String> = []

    /// Sessions outside every registered workspace land in one group rather than
    /// one group per directory. Splitting them per cwd made the phone list
    /// disagree with the Harness sidebar, which only lists registered
    /// workspaces — 29 of 36 sessions were phantom workspaces in practice.
    private static let unfiledGroup = "Other"

    private var groupedSessions: [(String, [DSHSessionSummary])] {
        let visibleSessions = model.sessions.filter {
            model.showArchivedSessions || $0.archived != true
        }
        let groups = Dictionary(grouping: visibleSessions) { session in
            session.workspaceName ?? Self.unfiledGroup
        }
        // Registered workspaces first, the unfiled bucket last.
        return groups.keys.sorted { left, right in
            if left == Self.unfiledGroup { return false }
            if right == Self.unfiledGroup { return true }
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
        .map { ($0, (groups[$0] ?? []).sorted { $0.updatedAt > $1.updatedAt }) }
    }

    private func isExpanded(_ group: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(group) },
            set: { expanded in
                if expanded { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
            }
        )
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                ForEach(groupedSessions, id: \.0) { group, sessions in
                    Section(isExpanded: isExpanded(group)) {
                        ForEach(sessions) { session in
                            NavigationLink(value: session.id) {
                                SessionRow(session: session)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    model.archive(session, archived: session.archived != true)
                                } label: {
                                    Label(session.archived == true ? "Unarchive" : "Archive",
                                          systemImage: session.archived == true ? "tray.and.arrow.up" : "archivebox")
                                }
                                .tint(session.archived == true ? .green : .orange)
                            }
                            .contextMenu {
                                Button {
                                    model.archive(session, archived: session.archived != true)
                                } label: {
                                    Label(session.archived == true ? "Unarchive" : "Archive",
                                          systemImage: session.archived == true ? "tray.and.arrow.up" : "archivebox")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(group)
                            Spacer()
                            Text("\(sessions.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                Section { EmptyView() } header: { connectionHeader }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            .overlay {
                if groupedSessions.isEmpty {
                    ContentUnavailableView("No sessions", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Create your first Harness session."))
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: String.self) { id in
                ConversationView(sessionID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.forgetPairing() } label: {
                        Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { model.createSession() } label: {
                            Label("New session", systemImage: "plus")
                        }
                        Toggle(isOn: Binding(get: { model.showArchivedSessions }, set: model.setShowArchived)) {
                            Label("Show archived", systemImage: "archivebox")
                        }
                        Button { refreshSessions() } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Label("Session actions", systemImage: didRefresh ? "checkmark.circle.fill" : "ellipsis.circle")
                    }
                }
            }
            .onChange(of: model.selectedSessionID) { _, sessionID in
                guard let sessionID else { return }
                if navigationPath.last != sessionID {
                    navigationPath.append(sessionID)
                }
                model.selectedSessionID = nil
            }
            // Command failures used to be invisible: the app stored the message
            // on the model and never rendered it, so "New session" simply
            // appeared to do nothing at all.
            .alert("Something went wrong", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { presented in if !presented { model.errorMessage = nil } }
            ), presenting: model.errorMessage) { _ in
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: { message in
                Text(message)
            }
            // The model requests the initial list after connection.ready.
            // Doing it from onAppear races the Relay WebSocket handshake.
        }
    }

    private func refreshSessions() {
        model.refreshSessions()
        didRefresh = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didRefresh = false
        }
    }

    private var connectionHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
            Text(connectionLabel)
                .font(.caption)
            Spacer()
            Text(model.machineName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
    }

    private var connectionLabel: String {
        switch model.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))…"
        case .failed: return "Connection failed"
        case .disconnected: return "Disconnected"
        }
    }

    private var connectionColor: Color {
        switch model.connectionState {
        case .connected: return .green
        case .failed: return .red
        default: return .orange
        }
    }
}

private struct SessionRow: View {
    let session: DSHSessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title.isEmpty ? "Untitled session" : session.title)
                .font(.body.weight(.medium))
            HStack(spacing: 6) {
                if let cwd = session.cwd {
                    Label(cwd, systemImage: "folder")
                        .lineLimit(1)
                }
                if let model = session.model {
                    Label(model, systemImage: "cpu")
                }
                if session.archived == true {
                    Label("Archived", systemImage: "archivebox")
                }
                if let permission = session.permissionMode {
                    Text(permissionLabel(permission))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if session.updatedAt > 0 {
                Text(Date(timeIntervalSince1970: Double(session.updatedAt) / 1_000), style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func permissionLabel(_ value: String) -> String {
        switch value {
        case "never": return "No approvals"
        case "read-only": return "Read only"
        case "danger-full-access": return "Full access"
        case "ask": return "Ask"
        default: return "Workspace"
        }
    }
}

struct SessionListView_Previews: PreviewProvider {
    static var previews: some View {
        SessionListView().environmentObject(DSHAppModel.preview())
    }
}

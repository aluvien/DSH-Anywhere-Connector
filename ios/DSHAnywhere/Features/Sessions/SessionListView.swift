import SwiftUI

struct SessionListView: View {
    @EnvironmentObject private var model: DSHAppModel
    @State private var navigationPath: [String] = []
    @State private var didRefresh = false
    @State private var showSettings = false

    /// Grouping, filtering and sorting live in Core so they are unit-tested;
    /// this view only arranges what it is handed. Sessions outside every
    /// registered workspace share one bucket, never one group per directory.
    private var groups: [DSHSessionGroup] {
        model.sessions.groupedForList(model.sessionGrouping, showArchived: model.showArchivedSessions)
    }

    private func isExpanded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !model.isGroupCollapsed(id) },
            set: { model.setGroup(id, collapsed: !$0) }
        )
    }

    @ViewBuilder
    private func sectionHeader(_ group: DSHSessionGroup) -> some View {
        // A flat list has no sections to label.
        if !group.title.isEmpty {
            HStack {
                Text(group.title)
                Spacer()
                Text("\(group.sessions.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                ForEach(groups) { group in
                    Section(isExpanded: isExpanded(group.id)) {
                        ForEach(group.sessions) { session in
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
                        sectionHeader(group)
                    }
                }
                Section { EmptyView() } header: { connectionHeader }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView("No sessions", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Create your first Harness session."))
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: String.self) { id in
                ConversationView(sessionID: id)
            }
            .toolbar {
                // Brand mark rather than a control on the left, matching the
                // reference app: the two things you can actually do live in the
                // capsule on the right.
                ToolbarItem(placement: .topBarLeading) {
                    Image("WhaleLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Two adjacent toolbar items, not two circular buttons with
                    // custom chrome: the system already draws one shared capsule
                    // around grouped items, and our own material layer inside it
                    // read as a second colour.
                    HStack(spacing: 0) {
                        Menu {
                            Button { model.createSession() } label: {
                                Label("New session", systemImage: "plus")
                            }
                            Divider()
                            Toggle(isOn: Binding(
                                get: { model.groupsSessionsByWorkspace },
                                set: model.setGroupsSessionsByWorkspace
                            )) {
                                Label("Group by workspace", systemImage: "square.grid.2x2")
                            }
                            Toggle(isOn: Binding(get: { model.showArchivedSessions }, set: model.setShowArchived)) {
                                Label("Show archived", systemImage: "archivebox")
                            }
                            Button { refreshSessions() } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        } label: {
                            Image(systemName: didRefresh
                                  ? "checkmark.circle.fill"
                                  : "line.3.horizontal.decrease")
                                .frame(width: 44, height: 32)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Filter and sort sessions")

                        Divider().frame(height: 18)

                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                                .frame(width: 44, height: 32)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(model)
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
            // Title and recency share one line, so a row costs two lines instead
            // of three and more sessions fit on a phone screen.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.title.isEmpty ? "Untitled session" : session.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if session.updatedAt > 0 {
                    Text(Date(timeIntervalSince1970: Double(session.updatedAt) / 1_000), style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
            }
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

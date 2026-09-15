import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// The small project avatar used by Happy's flat session list.  DSH Anywhere
/// does not receive a project-avatar URL from the Harness, so we keep the
/// geometry stable and use a deterministic, branded mark instead of making
/// every row jump between a placeholder and an image.
struct DSHHappyAvatar: View {
    let size: CGFloat
    var faded = false

    var body: some View {
        ZStack {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.02, green: 0.72, blue: 0.28),
                                     Color(red: 0.02, green: 0.54, blue: 0.22)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Happy's project mark is three slightly organic purple
                // ribbons. Capsules stay crisp at both supported sizes.
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.74, green: 0.25, blue: 0.98),
                                         Color(red: 0.98, green: 0.30, blue: 0.78)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: size * 0.60, height: max(3, size * 0.12))
                        .rotationEffect(.degrees(index == 1 ? 0 : index == 0 ? -3 : 3))
                        .offset(y: CGFloat(index - 1) * size * 0.16)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay { Circle().stroke(Color.white.opacity(0.14), lineWidth: max(0.5, size * 0.018)) }

            // Small orange sunburst badge, matching Happy's lower-right
            // activity marker without depending on an external image asset.
            ZStack {
                ForEach(0..<8, id: \.self) { index in
                    Capsule()
                        .fill(Color(red: 0.93, green: 0.43, blue: 0.27))
                        .frame(width: max(1.5, size * 0.045), height: size * 0.24)
                        .rotationEffect(.degrees(Double(index) * 45))
                }
                Circle()
                    .fill(Color(red: 0.22, green: 0.10, blue: 0.09))
                    .frame(width: size * 0.16, height: size * 0.16)
            }
            .frame(width: size * 0.30, height: size * 0.30)
            .background(Color(red: 0.16, green: 0.08, blue: 0.08), in: Circle())
            .overlay { Circle().stroke(Color.black.opacity(0.55), lineWidth: max(0.5, size * 0.018)) }
            .offset(x: size * 0.40, y: size * 0.40)
        }
        .frame(width: size, height: size)
        .opacity(faded ? 0.45 : 1)
    }
}

/// The home screen is deliberately a light-weight workspace browser. A
/// session can stream hundreds of events while it is running; rendering a
/// system `List` section for every event made the whole page re-diff and flash.
/// A stable `ScrollView`/`LazyVStack` keeps the rows in place and leaves the
/// transcript screen to handle the high-frequency part of a turn.
struct SessionListView: View {
    @EnvironmentObject private var model: DSHAppModel
    @State private var navigationPath: [String] = []
    @State private var didRefresh = false
    @State private var showSettings = false
    @State private var showNewSession = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--dsh-preview-new-session")
        #else
        return false
        #endif
    }()
    @State private var newSessionWorkspaceID: String?
    @State private var showRenameWorkspace = false
    @State private var renameWorkspaceID = ""
    @State private var renameWorkspaceText = ""
    @State private var workspacePendingDeletion: DSHSessionGroup?
    @State private var showDeleteWorkspaceConfirmation = false

    /// Grouping, filtering and sorting live in Core so they are unit-tested;
    /// this view only arranges what it is handed.
    private var groups: [DSHSessionGroup] {
        model.sessions
            .groupedForList(model.sessionGrouping, showArchived: model.showArchivedSessions)
            .filter { !model.hiddenWorkspaceIDs.contains($0.id) }
            .map { group in
                let title = group.id == DSHSessionGroup.flatGroupID
                    ? group.title
                    : model.workspaceDisplayName(for: group.id, fallback: group.title)
                return DSHSessionGroup(id: group.id, title: title, sessions: group.sessions, isUnfiled: group.isUnfiled)
            }
    }

    /// Happy's phone home is a single activity-sorted chat column.  Grouping
    /// remains available from the filter menu, but the flat view is the
    /// default so the first screen has the same visual rhythm as Happy.
    private var flatSessions: [DSHSessionSummary] {
        model.sessions
            .groupedForList(.flat, showArchived: model.showArchivedSessions)
            .flatMap(\.sessions)
            .filter { session in
                guard let workspaceID = session.workspaceId else { return true }
                return !model.hiddenWorkspaceIDs.contains(workspaceID)
            }
    }

    private var hasVisibleSessions: Bool {
        model.groupsSessionsByWorkspace ? !groups.isEmpty : !flatSessions.isEmpty
    }

    private var hasArchivedSessions: Bool {
        model.sessions.contains { $0.archived == true }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.groupsSessionsByWorkspace {
                        ForEach(groups) { group in
                            workspaceSection(group)
                        }
                        if hasArchivedSessions && !model.showArchivedSessions && !groups.isEmpty {
                            archivedSessionsButton
                        }
                    } else {
                        flatHomeContent
                    }
                }
                // A grouping switch changes the entire row tree (flat rows
                // become workspace cards and vice versa). Giving each mode a
                // stable identity prevents SwiftUI from reusing the previous
                // tree after the menu closes, which used to make the toggle
                // appear to do nothing until a later refresh.
                .id(model.groupsSessionsByWorkspace ? "workspace-groups" : "flat-sessions")
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            // Keep the bottom composer a real system TextField while allowing
            // an interactive downward drag to dismiss the keyboard. Without
            // this, the focused field captures the first swipe and makes the
            // new-session sheet feel stuck on compact screens.
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemBackground))
            .overlay {
                if model.hasLoadedSessions && !hasVisibleSessions {
                    emptyHomeState
                }
            }
            // Keep the Happy-style navigation bar fixed while project cards
            // scroll underneath it. Putting the bar in the ScrollView made it
            // disappear after the first swipe and was the opposite of the
            // reference interaction.
            .safeAreaInset(edge: .top, spacing: 0) {
                happyHeader
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                homeDock
            }
            // There is no implicit row insertion/removal animation on the
            // home screen. The Connector can send a snapshot after every
            // reconnect, and animating that snapshot is the source of the
            // visible flash users reported.
            .transaction { transaction in transaction.animation = nil }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                ConversationView(sessionID: id)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(model)
            }
            .fullScreenCover(isPresented: $showNewSession) {
                NewSessionSheet(initialWorkspaceID: newSessionWorkspaceID)
                    .environmentObject(model)
            }
            .alert("重命名项目", isPresented: $showRenameWorkspace) {
                TextField("项目名称", text: $renameWorkspaceText)
                Button("取消", role: .cancel) { }
                Button("保存") {
                    model.renameWorkspace(id: renameWorkspaceID, to: renameWorkspaceText)
                }
            }
            .confirmationDialog("删除项目？", isPresented: $showDeleteWorkspaceConfirmation,
                                titleVisibility: .visible, presenting: workspacePendingDeletion) { group in
                Button("删除并归档会话", role: .destructive) {
                    model.deleteWorkspace(group)
                }
                Button("取消", role: .cancel) { }
            } message: { group in
                Text("将删除项目“\(group.title)”并归档其中的 \(group.sessions.count) 个会话。项目目录和历史记录仍保留在 Mac 上。")
            }
            .onChange(of: model.selectedSessionID) { _, sessionID in
                guard let sessionID else { return }
                if navigationPath.last != sessionID {
                    navigationPath.append(sessionID)
                }
                model.selectedSessionID = nil
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { presented in if !presented { model.errorMessage = nil } }
            ), presenting: model.errorMessage) { _ in
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: { message in
                Text(message)
            }
        }
    }

    /// Happy's navigation bar: a 44pt workspace button, a centred title, and an
    /// 88pt filter/settings capsule.  The line below the title is deliberately
    /// compact: one status dot and the active Mac name, with no redundant
    /// “Connected” label taking up the centre slot.
    private var happyHeader: some View {
        ZStack {
            // Keep the title in its own full-width layer.  The trailing
            // filter/settings capsule is wider than the leading workspace
            // button, so an ordinary HStack would shift the title left.
            VStack(spacing: 1) {
                Text("Sessions")
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(deviceStatusColor)
                        .frame(width: 6, height: 6)
                    Text(deviceName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityValue("\(deviceName), \(deviceStatusAccessibilityLabel)")
            .allowsHitTesting(false)

            HStack(spacing: 10) {
            Menu {
                Button { openNewSession() } label: {
                    Label("New session", systemImage: "plus")
                }
                Button { refreshSessions() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                if !model.workspaces.isEmpty {
                    Divider()
                    Section("New session in") {
                        ForEach(model.workspaces) { workspace in
                            Button { openNewSession(for: workspace) } label: {
                                Label(workspace.name, systemImage: "folder")
                            }
                        }
                    }
                }
                Divider()
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemBackground), in: Circle())
                    .overlay {
                        Circle().stroke(Color.primary.opacity(0.14), lineWidth: 0.75)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Workspace menu")

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                Menu {
                    Toggle(isOn: Binding(
                        get: { model.showArchivedSessions },
                        set: model.setShowArchived
                    )) {
                        Label("Show archived", systemImage: "archivebox")
                    }
                    Divider()
                    Toggle(isOn: Binding(
                        get: { model.groupsSessionsByWorkspace },
                        set: model.setGroupsSessionsByWorkspace
                    )) {
                        Label("Group by workspace", systemImage: "square.grid.2x2")
                    }
                    Button {
                        model.setGroupsSessionsByWorkspace(false)
                    } label: {
                        Label("Flat list", systemImage: model.groupsSessionsByWorkspace
                              ? "list.bullet" : "checkmark")
                    }
                    Divider()
                    Button { refreshSessions() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: didRefresh ? "checkmark" : "line.3.horizontal.decrease")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 48, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Filter sessions")

                Divider()
                    .frame(height: 22)
                    .overlay(Color.primary.opacity(0.16))

                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 48, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            // Two 44pt actions and a hairline seam: Happy's capsule is 88pt
            // wide, with no hidden padding that would make it feel oversized.
            .frame(width: 88, height: 44)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .overlay {
                Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 0.75)
            }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Color(.systemBackground).opacity(0.96))
    }

    /// Flat mode keeps the compact child-row rhythm used inside a project
    /// group.  The project card/header is omitted here, so the workspace name
    /// is shown as the row's secondary line to retain that context.
    @ViewBuilder
    private var flatHomeContent: some View {
        ForEach(Array(flatSessions.enumerated()), id: \.element.id) { index, session in
            NavigationLink(value: session.id) {
                SessionRow(session: session,
                           showWorkspaceName: true,
                           isHighlighted: session.running == true || model.isSessionUnread(session))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    model.archive(session, archived: session.archived != true)
                } label: {
                    Label(DSHLocalization.string(session.archived == true ? "Unarchive" : "Archive"),
                          systemImage: session.archived == true ? "tray.and.arrow.up" : "archivebox")
                }
            }

            if index < flatSessions.count - 1 {
                Divider()
                    .padding(.leading, 48)
                    .opacity(0.52)
            }
        }

        if hasArchivedSessions {
            Button {
                model.setShowArchived(!model.showArchivedSessions)
            } label: {
                HStack(spacing: 10) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.28))
                        .frame(height: 1)
                    Text(DSHLocalization.string(model.showArchivedSessions ? "Hide archived" : "Show archived"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Rectangle()
                        .fill(Color.secondary.opacity(0.28))
                        .frame(height: 1)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Happy keeps the archive affordance quiet: it only appears when there
    /// is something hidden, and it sits below the active project groups rather
    /// than taking over the header.
    private var archivedSessionsButton: some View {
        Button {
            model.setShowArchived(true)
        } label: {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(height: 1)
                Text("Show archived")
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(height: 1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The centre state mirrors Happy's machine-unreachable screen while
    /// remaining useful for an archive-only account.
    private var emptyHomeState: some View {
        let reachable = model.deviceStatus == .online || model.deviceStatus == .approvalRequired
        let machine = model.machineName.isEmpty ? "Mac" : model.machineName
        return VStack(spacing: 0) {
            Spacer(minLength: 0)

            emptyStateIcon(reachable: reachable)
                .padding(.bottom, 20)

            Text(reachable
                 ? DSHLocalization.string("No sessions yet")
                 : String(format: DSHLocalization.string("%@ is unreachable"), machine))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            Text(DSHLocalization.string(reachable
                 ? "Start one on a connected machine."
                 : "Bring a machine online to start a session."))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)

            Button(DSHLocalization.string(reachable ? "Start New Session" : "Troubleshoot")) {
                if reachable { openNewSession() } else { showSettings = true }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            if hasArchivedSessions {
                Button("Show archived") {
                    model.setShowArchived(true)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.subheadline.weight(.medium))
                .padding(.top, 12)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 82)
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private func emptyStateIcon(reachable: Bool) -> some View {
        if reachable {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.secondary)
        } else {
            // `cloud.slash` is not present in every SF Symbols runtime used by
            // our supported simulators. Build the same glyph from a stable
            // cloud outline and a diagonal stroke so the unreachable state
            // never loses its visual anchor.
            ZStack {
                Image(systemName: "cloud")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color.secondary)
                    .frame(width: 4, height: 72)
                    .rotationEffect(.degrees(-42))
            }
        }
    }

    /// A compact, always-visible entry point is the part of Happy's home screen
    /// that makes starting work feel immediate. It deliberately opens the
    /// native New Session sheet on tap, so the first prompt never bypasses the
    /// device/workspace/branch/model choices.
    private var homeDock: some View {
        return Button { openNewSession() } label: {
            HStack(spacing: 0) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .regular))
                    .frame(width: 44, height: 44)

                Divider()
                    .frame(height: 24)
                    .overlay(Color.primary.opacity(0.16))
                    .padding(.horizontal, 9)

                Text("Plan, ask, build…")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 44, height: 44)
                    .background(Color(.tertiarySystemBackground), in: Circle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New session")
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.75)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(.systemBackground).opacity(0.92))
    }

    @ViewBuilder
    private func workspaceSection(_ group: DSHSessionGroup) -> some View {
        let workspace = workspaceOption(for: group)
        let expanded = !model.isGroupCollapsed(group.id)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    toggle(group, currentlyExpanded: expanded)
                } label: {
                    Image(systemName: expanded ? "folder.fill" : "folder")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse project" : "Expand project")

                Button {
                    toggle(group, currentlyExpanded: expanded)
                } label: {
                    Text(group.title.isEmpty ? DSHLocalization.string("Sessions") : group.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                Menu {
                    Button { openNewSession(for: workspace) } label: {
                        Label("New session", systemImage: "plus")
                    }
                    Button { toggle(group, currentlyExpanded: expanded) } label: {
                        Label(DSHLocalization.string(expanded ? "Collapse project" : "Expand project"),
                              systemImage: expanded ? "chevron.up" : "chevron.down")
                    }
                    Button { refreshSessions() } label: {
                        Label("Refresh project", systemImage: "arrow.clockwise")
                    }
                    Button { beginRename(group) } label: {
                        Label("Rename project", systemImage: "pencil")
                    }
                    Button(role: .destructive) { beginDelete(group) } label: {
                        Label("Delete project", systemImage: "trash")
                    }
                    Divider()
                    Toggle(isOn: Binding(
                        get: { model.showArchivedSessions },
                        set: model.setShowArchived
                    )) {
                        Label("Show archived", systemImage: "archivebox")
                    }
                } label: {
                    projectHeaderActionIcon("ellipsis", weight: .semibold)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.primary)
                .tint(Color.primary)
                .accessibilityLabel("Project options")

                Button { openNewSession(for: workspace) } label: {
                    projectHeaderActionIcon("square.and.pencil", weight: .medium)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.primary)
                .tint(Color.primary)
                .accessibilityLabel("New session in \(group.title)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if expanded {
                Divider()
                    .padding(.horizontal, 14)
                    .opacity(0.55)

                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                    NavigationLink(value: session.id) {
                        GroupedSessionRow(
                            session: session,
                            isHighlighted: session.running == true || model.isSessionUnread(session)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            model.archive(session, archived: session.archived != true)
                        } label: {
                            Label(DSHLocalization.string(session.archived == true ? "Unarchive" : "Archive"),
                                  systemImage: session.archived == true ? "tray.and.arrow.up" : "archivebox")
                        }
                    }
                    if index < group.sessions.count - 1 {
                        Divider()
                            .padding(.horizontal, 20)
                            .opacity(0.45)
                    }
                }
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.75)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .id(group.id)
    }

    private func toggle(_ group: DSHSessionGroup, currentlyExpanded: Bool) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            model.setGroup(group.id, collapsed: currentlyExpanded)
        }
    }

    /// Project actions deliberately share one rendering path. `Menu` applies
    /// the accent tint more aggressively than a plain `Button`, so styling the
    /// two labels separately made the ellipsis and compose glyph look like two
    /// different priorities even when both used `.primary`.
    private func projectHeaderActionIcon(_ systemName: String,
                                         weight: Font.Weight) -> some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 18, weight: weight))
            .foregroundStyle(Color.primary)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
    }

    private func workspaceOption(for group: DSHSessionGroup) -> DSHWorkspaceOption? {
        guard let first = group.sessions.first,
              let id = first.workspaceId,
              let name = first.workspaceName else { return nil }
        return DSHWorkspaceOption(id: id, name: name)
    }

    private func openNewSession(for workspace: DSHWorkspaceOption? = nil) {
        newSessionWorkspaceID = workspace?.id
        showNewSession = true
    }

    private func beginRename(_ group: DSHSessionGroup) {
        renameWorkspaceID = group.id
        renameWorkspaceText = group.title
        showRenameWorkspace = true
    }

    private func beginDelete(_ group: DSHSessionGroup) {
        workspacePendingDeletion = group
        showDeleteWorkspaceConfirmation = true
    }

    private func refreshSessions() {
        model.refreshSessions()
        didRefresh = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didRefresh = false
        }
    }

    private var deviceName: String {
        let name = model.machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Mac" : name
    }

    /// The status hierarchy intentionally gives a pending approval precedence
    /// over the ordinary online state. A failed transport remains red so the
    /// user does not mistake a stale approval for a reachable machine.
    private var deviceStatusColor: Color {
        switch model.deviceStatus {
        case .offline: return .gray
        case .error: return .red
        case .online: return .green
        case .approvalRequired: return .yellow
        }
    }

    private var deviceStatusAccessibilityLabel: String {
        switch model.deviceStatus {
        case .offline: return "Offline"
        case .error: return "Error"
        case .online: return "Online"
        case .approvalRequired: return "Permission confirmation required"
        }
    }
}

private struct NewSessionSheet: View {
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    private let initialWorkspaceID: String?
    @State private var workspaceID: String
    @State private var permissionMode = "workspace-write"
    @State private var sessionTitle = ""
    @State private var workingDirectory = ""
    @State private var branch = "main"
    @State private var sessionMode = "standard"
    @State private var selectedProvider = ""
    @State private var selectedModel = ""
    @State private var selectedReasoningEffort: String?
    @State private var initialPrompt = ""
    @State private var initialAttachments: [DSHStagedAttachment] = []
    @State private var selectedInitialPhoto: PhotosPickerItem?
    @State private var showInitialPhotoPicker = false
    @State private var showInitialFileImporter = false
    @State private var showInitialCommandMenu = false

    init(initialWorkspaceID: String? = nil, initialPrompt: String = "") {
        self.initialWorkspaceID = initialWorkspaceID
        _workspaceID = State(initialValue: initialWorkspaceID ?? "")
        _initialPrompt = State(initialValue: initialPrompt)
    }

    private var selectedWorkspace: DSHWorkspaceOption? {
        model.workspaces.first { $0.id == workspaceID }
    }

    var body: some View {
        ZStack {
            // The reference is a native full-screen compose surface with the
            // current page softly visible underneath. The empty region is the
            // cancellation target, so there is no second toolbar competing
            // with the compact controls at the bottom.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .background(Color(.secondarySystemBackground), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")

                    Spacer(minLength: 0)

                    Text("New task")
                        .font(.headline.weight(.semibold))

                    Spacer(minLength: 0)

                    // Keep the header balanced while the create action stays
                    // in the shared composer below.
                    Color.clear
                        .frame(width: 40, height: 40)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)

                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 26) {
                    compactConfiguration

                    TextField("Task title (optional)", text: $sessionTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 21, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)

                    if !initialAttachments.isEmpty {
                        initialAttachmentStrip
                    }

                    initialPromptEditor
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }
        }
        .presentationBackground(.clear)
        .sheet(isPresented: $showInitialCommandMenu) {
            CommandMenuSheet(
                selectedPhoto: $selectedInitialPhoto,
                onFile: {
                    showInitialCommandMenu = false
                    showInitialFileImporter = true
                },
                onCommand: { command in
                    showInitialCommandMenu = false
                    initialPrompt = appendCommand(command, to: initialPrompt)
                },
                onDismiss: { showInitialCommandMenu = false }
            )
            .presentationDetents([.medium])
        }
        .photosPicker(isPresented: $showInitialPhotoPicker,
                      selection: $selectedInitialPhoto,
                      matching: .images)
        .fileImporter(isPresented: $showInitialFileImporter,
                      allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    initialAttachments.append(DSHStagedAttachment(
                        name: url.lastPathComponent,
                        data: data,
                        isImage: ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased())
                    ))
                }
            }
        }
        .onChange(of: selectedInitialPhoto) { _, item in
            guard let item else { return }
            Task { @MainActor in
                defer { selectedInitialPhoto = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        model.errorMessage = "无法读取图片，请重试。"
                        return
                    }
                    let optimized = await optimizedPhotoDataOffMain(data)
                    initialAttachments.append(DSHStagedAttachment(name: "photo.jpg",
                                                                  data: optimized,
                                                                  isImage: true))
                } catch {
                    model.errorMessage = "无法读取图片，请重试。"
                }
            }
        }
        .onAppear {
            if workspaceID.isEmpty, let first = model.workspaces.first {
                selectWorkspace(first)
            }
            // If the project disappeared between tapping the button and
            // opening the sheet, fall back to the first current workspace.
            if initialWorkspaceID != nil, selectedWorkspace == nil,
               let first = model.workspaces.first {
                selectWorkspace(first)
            }
            if workingDirectory.isEmpty,
               let cwd = model.sessions.first(where: { $0.workspaceId == workspaceID })?.cwd {
                workingDirectory = cwd
            }
            if selectedProvider.isEmpty, let catalog = model.modelCatalog {
                selectedProvider = catalog.default.provider
                selectedModel = catalog.default.model
                selectedReasoningEffort = catalog.default.reasoningEffort
            }
        }
        .onChange(of: model.machineID) { _, _ in
            workspaceID = ""
            workingDirectory = ""
            branch = "main"
        }
        .onChange(of: model.workspaces) { _, workspaces in
            if workspaceID.isEmpty, let first = workspaces.first {
                selectWorkspace(first)
            }
        }
    }

    /// The four selectors mirror the compact information cluster in the
    /// reference: machine, project directory, branch/worktree and mode. They
    /// are native `Menu` controls but deliberately look like information rows
    /// rather than a settings form.
    private var compactConfiguration: some View {
        VStack(alignment: .leading, spacing: 20) {
            machineSelector
            workspaceSelector
            branchSelector
            modeSelector
        }
        .padding(.horizontal, 14)
    }

    private var machineSelector: some View {
        Menu {
            if model.machines.isEmpty {
                Text(model.machineName.isEmpty ? "Mac" : model.machineName)
            } else {
                ForEach(model.machines, id: \.machineId) { machine in
                    Button {
                        model.switchMachine(machine)
                    } label: {
                        Label(machine.machineName,
                              systemImage: machine.machineId == model.activeMachine?.machineId
                                ? "checkmark" : "desktopcomputer")
                    }
                }
            }
        } label: {
            newSessionInfoRow(icon: "desktopcomputer",
                              title: model.machineName.isEmpty ? "Mac" : model.machineName)
        }
        .buttonStyle(.plain)
        .tint(.primary)
    }

    private var workspaceSelector: some View {
        Menu {
            if model.workspaces.isEmpty {
                Text("暂无可用工作区")
            } else {
                ForEach(model.workspaces) { workspace in
                    Button {
                        selectWorkspace(workspace)
                    } label: {
                        Label(workspace.name,
                              systemImage: workspace.id == workspaceID ? "checkmark" : "folder")
                    }
                }
            }
        } label: {
            newSessionInfoRow(icon: "folder",
                              title: displayedWorkingDirectory)
        }
        .buttonStyle(.plain)
        .tint(.primary)
    }

    private var branchSelector: some View {
        Menu {
            Button {
                branch = ""
            } label: {
                Label("不使用工作树", systemImage: branch.isEmpty ? "checkmark" : "arrow.triangle.branch")
            }
            ForEach(branchOptions, id: \.self) { option in
                Button {
                    branch = option
                } label: {
                    Label(option, systemImage: branch == option ? "checkmark" : "arrow.triangle.branch")
                }
            }
        } label: {
            newSessionInfoRow(icon: "arrow.triangle.branch",
                              title: branch.isEmpty ? "不使用工作树" : branch)
        }
        .buttonStyle(.plain)
        .tint(.primary)
    }

    private var modeSelector: some View {
        Menu {
            modeButton("standard", title: "标准模式", icon: "sparkles")
            modeButton("ptc", title: "PTC 模式", icon: "list.clipboard")
            modeButton("custom", title: "自建模式", icon: "slider.horizontal.3")
        } label: {
            newSessionInfoRow(icon: "cpu", title: sessionModeLabel)
        }
        .buttonStyle(.plain)
        .tint(.primary)
    }

    private func modeButton(_ mode: String, title: String, icon: String) -> some View {
        Button { sessionMode = mode } label: {
            Label(title, systemImage: sessionMode == mode ? "checkmark" : icon)
        }
    }

    private func newSessionInfoRow(icon: String, title: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 21, weight: .medium))
                .frame(width: 28)
            Text(title)
                .font(.system(size: 18, weight: .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.primary)
        .frame(minHeight: 32)
        .contentShape(Rectangle())
    }

    private var displayedWorkingDirectory: String {
        let path = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return selectedWorkspace?.name ?? "选择工作区" }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0] == "Users" else { return path }
        let suffix = components.dropFirst(2).joined(separator: "/")
        return suffix.isEmpty ? "~" : "~/\(suffix)"
    }

    private var branchOptions: [String] {
        var values = Set(model.sessions
            .filter { workspaceID.isEmpty || $0.workspaceId == workspaceID }
            .compactMap { $0.branch?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        values.insert("main")
        return values.sorted { lhs, rhs in
            if lhs == "main" { return true }
            if rhs == "main" { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private var sessionModeLabel: String {
        switch sessionMode {
        case "ptc": return "PTC 模式"
        case "custom": return "自建模式"
        default: return "标准模式"
        }
    }

    private func selectWorkspace(_ workspace: DSHWorkspaceOption) {
        workspaceID = workspace.id
        guard let recent = model.sessions
            .filter({ $0.workspaceId == workspace.id })
            .max(by: { $0.updatedAt < $1.updatedAt }) else {
            workingDirectory = ""
            branch = "main"
            return
        }
        workingDirectory = recent.cwd ?? ""
        branch = recent.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "main"
        if branch.isEmpty { branch = "main" }
    }

    private var machineInfo: some View {
        HStack(spacing: 14) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.machineName.isEmpty ? "Mac" : model.machineName)
                    .font(.headline)
                Text(machineStatusLabel)
                    .font(.caption)
                    .foregroundStyle(machineStatusColor)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var machineStatusLabel: String {
        switch model.deviceStatus {
        case .offline: return "离线"
        case .error: return "连接错误"
        case .online: return "已连接"
        case .approvalRequired: return "需要确认权限"
        }
    }

    private var machineStatusColor: Color {
        switch model.deviceStatus {
        case .offline: return .gray
        case .error: return .red
        case .online: return .green
        case .approvalRequired: return .yellow
        }
    }

    private var workspaceChooser: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Workspace")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if model.workspaces.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No workspace is available yet")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 58)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                Menu {
                    ForEach(model.workspaces) { workspace in
                        Button {
                            workspaceID = workspace.id
                        } label: {
                            Label(workspace.name, systemImage: workspace.id == workspaceID ? "checkmark" : "folder")
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                        Text(selectedWorkspace?.name ?? "Select workspace")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 58)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Workspace " + (selectedWorkspace?.name ?? ""))
            }
        }
    }

    private var modeChooser: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("模式与权限")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 1) {
                sessionModeOption(mode: "standard", title: "标准模式", detail: "适合日常问答与代码任务。", icon: "sparkles")
                sessionModeOption(mode: "ptc", title: "PTC 模式", detail: "先规划，再执行代码任务。", icon: "list.clipboard")
                sessionModeOption(mode: "custom", title: "自建模式", detail: "使用本机 Harness 的自定义预设。", icon: "slider.horizontal.3")
                Divider().padding(.horizontal, 16)
                permissionOption(
                    mode: "read-only",
                    title: "仅可查看",
                    detail: "只能读取工作区内容。",
                    icon: "eye"
                )
                permissionOption(
                    mode: "workspace-write",
                    title: "工作区内修改",
                    detail: "可以读取并修改所选工作区文件。",
                    icon: "folder"
                )
                permissionOption(
                    mode: "danger-full-access",
                    title: "完全权限",
                    detail: "可以读写工作区之外的文件。",
                    icon: "lock.open"
                )
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func sessionModeOption(mode: String, title: String, detail: String, icon: String) -> some View {
        Button { sessionMode = mode } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(sessionMode == mode ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .medium))
                    Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: sessionMode == mode ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(sessionMode == mode ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pathAndBranchChooser: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("项目目录与分支")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    TextField("项目目录（可选）", text: $workingDirectory)
                        .textFieldStyle(.plain)
                }
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                    TextField("分支", text: $branch)
                        .textFieldStyle(.plain)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var modelChooser: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("模型")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Menu {
                if let catalog = model.modelCatalog {
                    ForEach(catalog.groups) { group in
                        Section(group.name) {
                            ForEach(group.models) { item in
                                Button {
                                    selectedProvider = group.id
                                    selectedModel = item.id
                                    selectedReasoningEffort = item.reasoning?.defaultEffort
                                } label: {
                                    Label(item.name, systemImage: selectedModel == item.id ? "checkmark" : "cpu")
                                }
                            }
                        }
                    }
                } else {
                    Button("刷新模型列表") { model.sendModelCatalog() }
                }
            } label: {
                HStack {
                    Image(systemName: "cpu")
                        .foregroundStyle(.tint)
                    Text(selectedModel.isEmpty ? "选择模型" : selectedModel)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 54)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    /// The first prompt uses the same compact composer as an existing
    /// conversation. Its plus action is the same three-entry native menu;
    /// selecting files only stages them locally until Create/send commits the
    /// new session.
    private var initialPromptEditor: some View {
        DSHCompactComposer(text: $initialPrompt,
                           placeholder: DSHLocalization.string("Send a message, / command, @ file or conversation"),
                           hasAttachments: !initialAttachments.isEmpty,
                           onSubmit: createSession) {
            DSHComposerQuickActionsMenu(
                onCommand: { showInitialCommandMenu = true },
                onPhoto: { showInitialPhotoPicker = true },
                onFile: { showInitialFileImporter = true }
            )

            initialPermissionMenu

            Spacer(minLength: 4)

            initialModelMenu

            initialReasoningMenu

            Button(action: createSession) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
            }
            .disabled(initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && initialAttachments.isEmpty)
            .accessibilityLabel("Create session")
        }
    }

    private var initialAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(initialAttachments) { attachment in
                    HStack(spacing: 6) {
                        if attachment.isImage, let image = UIImage(data: attachment.data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        Label(attachment.name, systemImage: attachment.isImage ? "photo" : "paperclip")
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            initialAttachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除附件")
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 6)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: .capsule)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var initialPermissionMenu: some View {
        Menu {
            Button { permissionMode = "read-only" } label: {
                Label("Read only", systemImage: permissionMode == "read-only" ? "checkmark" : "eye")
            }
            Button { permissionMode = "workspace-write" } label: {
                Label("Workspace write", systemImage: permissionMode == "workspace-write" ? "checkmark" : "folder")
            }
            Button { permissionMode = "danger-full-access" } label: {
                Label("Full access", systemImage: permissionMode == "danger-full-access" ? "checkmark" : "lock.open")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield")
                    .font(.title3)
                Text(initialPermissionLabel)
                    .font(.system(size: 14, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .accessibilityLabel("Permission: \(initialPermissionLabel)")
    }

    private var initialPermissionLabel: String {
        switch permissionMode {
        case "read-only": return DSHLocalization.string("Read only")
        case "danger-full-access": return DSHLocalization.string("Full access")
        default: return DSHLocalization.string("Workspace write")
        }
    }

    private var initialModelMenu: some View {
        Menu {
            if let catalog = model.modelCatalog {
                ForEach(catalog.groups) { group in
                    Section(group.name) {
                        ForEach(group.models) { item in
                            Button {
                                selectedProvider = group.id
                                selectedModel = item.id
                                selectedReasoningEffort = item.reasoning?.defaultEffort
                            } label: {
                                Label(item.name,
                                      systemImage: selectedModel == item.id ? "checkmark" : "cpu")
                            }
                        }
                    }
                }
            } else {
                Button("刷新模型列表") { model.sendModelCatalog() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(initialModelLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.78)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.system(size: 14, weight: .regular))
        }
        .accessibilityLabel("Model: \(initialModelLabel)")
    }

    @ViewBuilder private var initialReasoningMenu: some View {
        if let reasoning = selectedModelReasoning, !reasoning.efforts.isEmpty {
            Menu {
                ForEach(reasoning.efforts) { effort in
                    Button {
                        selectedReasoningEffort = effort.id
                    } label: {
                        Label(effort.name,
                              systemImage: effort.id == effectiveReasoningEffort
                                ? "checkmark" : "brain.head.profile")
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(selectedReasoningName(in: reasoning))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .font(.system(size: 14, weight: .regular))
                .frame(maxWidth: 70)
            }
            .accessibilityLabel("Reasoning effort")
        }
    }

    private var selectedModelReasoning: DSHModelReasoning? {
        guard let catalog = model.modelCatalog else { return nil }
        if let group = catalog.groups.first(where: { $0.id == selectedProvider }),
           let item = group.models.first(where: { $0.id == selectedModel }) {
            return item.reasoning
        }
        return catalog.groups.lazy
            .compactMap { $0.models.first(where: { $0.id == selectedModel })?.reasoning }
            .first
    }

    private var effectiveReasoningEffort: String {
        selectedReasoningEffort
            ?? selectedModelReasoning?.defaultEffort
            ?? selectedModelReasoning?.efforts.first?.id
            ?? ""
    }

    private func selectedReasoningName(in reasoning: DSHModelReasoning) -> String {
        reasoning.efforts.first(where: { $0.id == effectiveReasoningEffort })?.name
            ?? effectiveReasoningEffort
    }

    private var initialModelLabel: String {
        guard !selectedModel.isEmpty else { return "选择模型" }
        return model.modelLabel(for: DSHModelSelection(
            provider: selectedProvider.isEmpty ? "deepseek" : selectedProvider,
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort
        ))
    }

    private func appendCommand(_ command: String, to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/\(command) " : "\(text)\n/\(command) "
    }

    private func permissionOption(mode: String, title: String, detail: String, icon: String) -> some View {
        Button { permissionMode = mode } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(permissionMode == mode ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: permissionMode == mode ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(permissionMode == mode ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(permissionMode == mode ? .isSelected : [])
    }

    private func createSession() {
        guard !model.workspaces.isEmpty else { return }
        let selection = selectedModel.isEmpty ? nil : DSHModelSelection(
            provider: selectedProvider.isEmpty ? "deepseek" : selectedProvider,
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort
        )
        model.createSession(in: selectedWorkspace,
                            title: sessionTitle.isEmpty ? "新会话" : sessionTitle,
                            workingDirectory: workingDirectory,
                            branch: branch,
                            mode: sessionMode,
                            model: selection,
                            permissionMode: permissionMode,
                            initialPrompt: initialPrompt,
                            initialAttachments: initialAttachments)
        dismiss()
    }
}

private struct SessionRow: View {
    let session: DSHSessionSummary
    let showWorkspaceName: Bool
    let isHighlighted: Bool

    init(session: DSHSessionSummary, showWorkspaceName: Bool = false, isHighlighted: Bool = false) {
        self.session = session
        self.showWorkspaceName = showWorkspaceName
        self.isHighlighted = isHighlighted
    }

    private var updatedLabel: String {
        guard session.updatedAt > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(session.updatedAt) / 1_000)
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dayFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MM/dd"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 9) {
            if showWorkspaceName {
                Image(systemName: "bubble.left")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isHighlighted ? Color.green : Color.secondary)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Session icon")
            } else {
                Circle()
                    .fill(session.running == true ? Color.green : Color.secondary.opacity(0.55))
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(session.running == true ? "Running" : "Session")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.isEmpty ? DSHLocalization.string("Untitled session") : session.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if showWorkspaceName,
                   let workspace = session.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !workspace.isEmpty {
                    Text(workspace)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if showWorkspaceName && !updatedLabel.isEmpty {
                Text(updatedLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }
        }
        .padding(.leading, showWorkspaceName ? 16 : 48)
        .padding(.trailing, 22)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// Rows inside a workspace card follow Happy's grouped layout: a compact icon
/// tile, one-line title, optional active tint, recency and a disclosure arrow.
/// The workspace name is intentionally omitted because the enclosing card
/// already provides that context.
private struct GroupedSessionRow: View {
    let session: DSHSessionSummary
    let isHighlighted: Bool

    private var title: String {
        session.title.isEmpty ? "Untitled session" : session.title
    }

    private var iconName: String {
        let normalized = title.lowercased()
        if normalized.contains("bash") || normalized.contains("run ")
            || normalized.contains("eval") || normalized.contains("terminal") {
            return "chevron.left.forwardslash.chevron.right"
        }
        if normalized.contains("code") || normalized.contains("refactor")
            || normalized.contains("model") || normalized.contains("read") {
            return "doc.text"
        }
        return "bubble.left"
    }

    private var updatedLabel: String {
        guard session.updatedAt > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(session.updatedAt) / 1_000)
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dayFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MM/dd"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isHighlighted ? Color.green : Color.primary)
                .frame(width: 36, height: 36)
                .accessibilityLabel("Session icon")

            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if !updatedLabel.isEmpty {
                Text(updatedLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// Flat activity row used by the Happy home screen.  The avatar is 60pt, the
/// title is 17pt, and the timestamp occupies a fixed right slot.  Workspace
/// paths stay in the project header rather than being repeated below every
/// session; a green dot marks a session that is currently active.
private struct HappySessionRow: View {
    let session: DSHSessionSummary

    private var title: String {
        session.title.isEmpty ? "Untitled session" : session.title
    }

    private var updatedLabel: String {
        guard session.updatedAt > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(session.updatedAt) / 1_000)
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dayFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MM/dd"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            DSHHappyAvatar(size: 60, faded: session.archived == true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(session.archived == true ? .secondary : .primary)
                        .lineLimit(1)

                    if session.running == true {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Active session")
                    }

                    Spacer(minLength: 8)

                    if !updatedLabel.isEmpty {
                        Text(updatedLabel)
                            .font(.system(size: 13, weight: .regular, design: .default))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Happy's flat rows use the same 16pt page inset as its header.  The
        // avatar's 60pt diameter and 12pt gap then line up with the divider
        // and leave the timestamp in a stable trailing column.
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct SessionListView_Previews: PreviewProvider {
    static var previews: some View {
        SessionListView().environmentObject(DSHAppModel.preview())
    }
}

// MARK: - ChatGPT Remote task home

/// The production home for DSH Anywhere.  The older `SessionListView` remains
/// in the target as a rollback/reference surface, while this view owns the
/// native Remote task experience: project cards, task rows, one stable header,
/// and a real text field for starting work.
struct DSHRemoteHomeView: View {
    @EnvironmentObject private var model: DSHAppModel
    @State private var navigationPath: [String] = []
    @State private var showSettings = false
    @State private var showNewTask = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--dsh-preview-new-session")
        #else
        return false
        #endif
    }()
    @State private var newTaskWorkspaceID: String?
    @State private var newTaskPrompt = ""
    @State private var didRefresh = false
    @State private var renameWorkspaceID = ""
    @State private var renameWorkspaceText = ""
    @State private var showRenameWorkspace = false
    @State private var pendingWorkspaceDeletion: DSHSessionGroup?
    @State private var showDeleteWorkspaceConfirmation = false

    private var groupedSessions: [DSHSessionGroup] {
        model.sessions
            .groupedForList(.byWorkspace, showArchived: model.showArchivedSessions)
            .filter { !model.hiddenWorkspaceIDs.contains($0.id) }
            .map { group in
                let title = group.id == DSHSessionGroup.flatGroupID
                    ? group.title
                    : model.workspaceDisplayName(for: group.id, fallback: group.title)
                return DSHSessionGroup(id: group.id, title: title,
                                       sessions: group.sessions,
                                       isUnfiled: group.isUnfiled)
            }
    }

    private var flatSessions: [DSHSessionSummary] {
        model.sessions
            .groupedForList(.flat, showArchived: model.showArchivedSessions)
            .flatMap(\.sessions)
            .filter { session in
                guard let workspaceID = session.workspaceId else { return true }
                return !model.hiddenWorkspaceIDs.contains(workspaceID)
            }
    }

    private var hasArchivedSessions: Bool {
        model.sessions.contains { $0.archived == true }
    }

    private var deviceName: String {
        let value = model.machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Mac" : value
    }

    private var deviceStatusColor: Color {
        switch model.deviceStatus {
        case .offline: return .gray
        case .error: return .red
        case .online: return .green
        case .approvalRequired: return .yellow
        }
    }

    private var deviceStatusLabel: String {
        switch model.deviceStatus {
        case .offline: return DSHLocalization.string("Offline")
        case .error: return DSHLocalization.string("Connection error")
        case .online: return DSHLocalization.string("Connected")
        case .approvalRequired: return DSHLocalization.string("Permission confirmation required")
        }
    }

    /// A session snapshot is authoritative only after the first one arrives.
    /// Treat the socket handshake as a separate loading phase so a reconnect
    /// never flashes an empty task browser before the existing tasks are
    /// restored. Once the machine is known to be offline/failed, switch to the
    /// actionable unreachable state instead of spinning forever.
    private var isLoadingTasks: Bool {
        guard !model.hasLoadedSessions else { return false }
        switch model.connectionState {
        case .connecting, .reconnecting:
            return true
        case .connected:
            return model.deviceStatus != .offline && model.deviceStatus != .error
        case .disconnected, .failed:
            return false
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if isLoadingTasks {
                        remoteLoadingState
                    } else if model.groupsSessionsByWorkspace {
                        if groupedSessions.isEmpty {
                            remoteEmptyState
                        } else {
                            ForEach(groupedSessions) { group in
                                remoteWorkspaceCard(group)
                            }
                        }
                    } else {
                        if flatSessions.isEmpty {
                            remoteEmptyState
                        } else {
                            ForEach(flatSessions) { session in
                                NavigationLink(value: session.id) {
                                    DSHRemoteTaskRow(session: session, showWorkspaceName: true)
                                        .environmentObject(model)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { archiveAction(for: session) }
                            }
                        }
                    }

                    if hasArchivedSessions {
                        archivedDivider
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 18)
                .id(model.groupsSessionsByWorkspace ? "remote-workspaces" : "remote-flat")
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                model.refreshSessions(includeArchived: model.showArchivedSessions)
                model.sendModelCatalog()
            }
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .top, spacing: 0) {
                remoteHeader
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                DSHRemoteTaskComposer(text: $newTaskPrompt,
                                      modelLabel: defaultModelLabel,
                                      onNewTask: { openNewTask() })
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                ConversationView(sessionID: id)
            }
            .transaction { transaction in
                // A task snapshot can contain hundreds of changed sessions
                // after a reconnect. Do not animate the entire list tree.
                transaction.animation = nil
            }
            .fullScreenCover(isPresented: $showNewTask, onDismiss: {
                newTaskPrompt = ""
                newTaskWorkspaceID = nil
            }) {
                NewSessionSheet(initialWorkspaceID: newTaskWorkspaceID,
                                initialPrompt: newTaskPrompt)
                    .environmentObject(model)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(model)
            }
            .alert("重命名项目", isPresented: $showRenameWorkspace) {
                TextField("项目名称", text: $renameWorkspaceText)
                Button("取消", role: .cancel) { }
                Button("保存") {
                    model.renameWorkspace(id: renameWorkspaceID, to: renameWorkspaceText)
                }
            }
            .confirmationDialog("删除项目？", isPresented: $showDeleteWorkspaceConfirmation,
                                titleVisibility: .visible,
                                presenting: pendingWorkspaceDeletion) { group in
                Button("删除并归档会话", role: .destructive) {
                    model.deleteWorkspace(group)
                }
                Button("取消", role: .cancel) { }
            } message: { group in
                Text("将删除项目“\(group.title)”并归档其中的 \(group.sessions.count) 个会话。项目目录和历史记录仍保留在 Mac 上。")
            }
            .onChange(of: model.selectedSessionID) { _, sessionID in
                guard let sessionID else { return }
                if navigationPath.last != sessionID {
                    navigationPath.append(sessionID)
                }
                model.selectedSessionID = nil
            }
            .task {
                if !model.hasLoadedSessions {
                    model.refreshSessions()
                }
            }
        }
    }

    private var remoteLoadingState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 116)
            ProgressView()
                .controlSize(.large)
                .tint(.secondary)
            Text(DSHLocalization.string("Loading tasks…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 116)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DSHLocalization.string("Loading tasks…"))
    }

    private var remoteHeader: some View {
        ZStack {
            VStack(spacing: 2) {
                Text("Remote")
                    .font(.system(size: 18, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(deviceStatusColor)
                        .frame(width: 7, height: 7)
                    Text("\(deviceStatusLabel) · \(deviceName)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)

            HStack(spacing: 10) {
                Menu {
                    Button { openNewTask() } label: {
                        Label("New task", systemImage: "plus")
                    }
                    Divider()
                    Toggle(isOn: Binding(get: {
                        model.groupsSessionsByWorkspace
                    }, set: model.setGroupsSessionsByWorkspace)) {
                        Label("Group by workspace", systemImage: "square.grid.2x2")
                    }
                    Toggle(isOn: Binding(get: {
                        model.showArchivedSessions
                    }, set: model.setShowArchived)) {
                        Label("Show archived", systemImage: "archivebox")
                    }
                    Divider()
                    Button { refreshTasks() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button { showSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(Color(.secondarySystemBackground), in: Circle())
                        .overlay { Circle().stroke(Color.primary.opacity(0.13), lineWidth: 0.75) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remote menu")

                Spacer(minLength: 0)

                HStack(spacing: 0) {
                    Menu {
                        Toggle(isOn: Binding(get: {
                            model.groupsSessionsByWorkspace
                        }, set: model.setGroupsSessionsByWorkspace)) {
                            Label("Group by workspace", systemImage: "square.grid.2x2")
                        }
                        Toggle(isOn: Binding(get: {
                            model.showArchivedSessions
                        }, set: model.setShowArchived)) {
                            Label("Show archived", systemImage: "archivebox")
                        }
                        Divider()
                        Button { refreshTasks() } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: didRefresh ? "checkmark" : "line.3.horizontal.decrease")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 48, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Filter tasks")

                    Divider()
                        .frame(height: 22)
                        .overlay(Color.primary.opacity(0.14))

                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 48, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }
                .frame(width: 98, height: 44)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .overlay { Capsule().stroke(Color.primary.opacity(0.13), lineWidth: 0.75) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(Color(.systemBackground).opacity(0.96))
    }

    @ViewBuilder
    private func remoteWorkspaceCard(_ group: DSHSessionGroup) -> some View {
        let expanded = !model.isGroupCollapsed(group.id)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Button {
                    toggleGroup(group, expanded: expanded)
                } label: {
                    Image(systemName: expanded ? "folder.fill" : "folder")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 28, height: 36)
                }
                .buttonStyle(.plain)

                Button {
                    toggleGroup(group, expanded: expanded)
                } label: {
                    Text(group.title.isEmpty ? DSHLocalization.string("Sessions") : group.title)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 6)

                Menu {
                    Button { openNewTask(for: group) } label: {
                        Label("New task", systemImage: "plus")
                    }
                    Button { toggleGroup(group, expanded: expanded) } label: {
                        Label(expanded ? "Collapse project" : "Expand project",
                              systemImage: expanded ? "chevron.up" : "chevron.down")
                    }
                    Button { refreshTasks() } label: {
                        Label("Refresh project", systemImage: "arrow.clockwise")
                    }
                    if !group.isUnfiled {
                        Button { beginRename(group) } label: {
                            Label("Rename project", systemImage: "pencil")
                        }
                        Button(role: .destructive) { beginDelete(group) } label: {
                            Label("Delete project", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 34, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Project options")

                Button { openNewTask(for: group) } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 34, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New task in \(group.title)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            if expanded {
                Divider().opacity(0.48)
                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                    NavigationLink(value: session.id) {
                        DSHRemoteTaskRow(session: session, showWorkspaceName: false)
                            .environmentObject(model)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { archiveAction(for: session) }

                    if index < group.sessions.count - 1 {
                        Divider().padding(.leading, 68).opacity(0.42)
                    }
                }
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.075), lineWidth: 0.75)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var remoteEmptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 96)
            Image(systemName: model.deviceStatus == .online
                  ? "bubble.left.and.bubble.right"
                  : "cloud")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.secondary)
            Text(model.deviceStatus == .online
                 ? DSHLocalization.string("No tasks yet")
                 : "\(deviceName) \(DSHLocalization.string("is unreachable"))")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(model.deviceStatus == .online
                 ? DSHLocalization.string("Start one on a connected machine.")
                 : DSHLocalization.string("Bring a machine online to start a session."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                if model.deviceStatus == .online { openNewTask() } else { showSettings = true }
            } label: {
                Text(model.deviceStatus == .online
                     ? DSHLocalization.string("New task")
                     : DSHLocalization.string("Troubleshoot"))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Spacer(minLength: 96)
        }
        .frame(maxWidth: .infinity)
    }

    private var archivedDivider: some View {
        Button {
            model.setShowArchived(!model.showArchivedSessions)
        } label: {
            HStack(spacing: 10) {
                Rectangle().fill(Color.secondary.opacity(0.28)).frame(height: 1)
                Text(DSHLocalization.string(model.showArchivedSessions ? "Hide archived" : "Show archived"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Image(systemName: model.showArchivedSessions ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                Rectangle().fill(Color.secondary.opacity(0.28)).frame(height: 1)
            }
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func archiveAction(for session: DSHSessionSummary) -> some View {
        Button {
            model.archive(session, archived: session.archived != true)
        } label: {
            Label(DSHLocalization.string(session.archived == true ? "Unarchive" : "Archive"),
                  systemImage: session.archived == true ? "tray.and.arrow.up" : "archivebox")
        }
    }

    private var defaultModelLabel: String {
        guard let selection = model.modelCatalog?.default else {
            return DSHLocalization.string("Select model")
        }
        return model.modelLabel(for: selection)
    }

    private func toggleGroup(_ group: DSHSessionGroup, expanded: Bool) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            model.setGroup(group.id, collapsed: expanded)
        }
    }

    private func openNewTask(for group: DSHSessionGroup) {
        let workspace = group.sessions.first.flatMap { session -> DSHWorkspaceOption? in
            guard let id = session.workspaceId else { return nil }
            return DSHWorkspaceOption(id: id,
                                      name: model.workspaceDisplayName(for: id,
                                                                        fallback: session.workspaceName ?? group.title))
        }
        openNewTask(for: workspace)
    }

    private func openNewTask(for workspace: DSHWorkspaceOption? = nil) {
        newTaskWorkspaceID = workspace?.id
        showNewTask = true
    }

    private func beginRename(_ group: DSHSessionGroup) {
        renameWorkspaceID = group.id
        renameWorkspaceText = group.title
        showRenameWorkspace = true
    }

    private func beginDelete(_ group: DSHSessionGroup) {
        pendingWorkspaceDeletion = group
        showDeleteWorkspaceConfirmation = true
    }

    private func refreshTasks() {
        model.refreshSessions()
        didRefresh = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didRefresh = false
        }
    }
}

/// A task row intentionally contains enough context to be useful without
/// opening it: title, project (in flat mode), mode/model, running/unread state,
/// and the last activity time.  SF Symbols are used instead of avatars so the
/// list remains stable while a task is streaming.
private struct DSHRemoteTaskRow: View {
    @EnvironmentObject private var model: DSHAppModel
    let session: DSHSessionSummary
    let showWorkspaceName: Bool

    private var title: String {
        let value = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? DSHLocalization.string("New session") : value
    }

    private var unread: Bool { model.isSessionUnread(session) }

    private var iconName: String {
        if session.running == true { return "arrow.triangle.2.circlepath" }
        let mode = (session.mode ?? session.agentPreset ?? "").lowercased()
        if mode.contains("ptc") || mode.contains("plan") { return "list.clipboard" }
        let lowerTitle = title.lowercased()
        if lowerTitle.contains("bash") || lowerTitle.contains("command") || lowerTitle.contains("run") {
            return "terminal"
        }
        if lowerTitle.contains("refactor") || lowerTitle.contains("code") {
            return "doc.text"
        }
        return "bubble.left"
    }

    private var iconColor: Color {
        if session.running == true { return .accentColor }
        if unread { return .green }
        return .secondary
    }

    private var updatedLabel: String {
        guard session.updatedAt > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(session.updatedAt) / 1_000)
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        if Calendar.current.isDateInYesterday(date) {
            return DSHLocalization.string("Yesterday")
        }
        return Self.dayFormatter.string(from: date)
    }

    private var contextLabel: String {
        var values: [String] = []
        if showWorkspaceName,
           let workspace = session.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspace.isEmpty {
            values.append(workspace)
        }
        values.append(model.modeLabel(for: session.id))
        let shortModel = model.shortModelName(for: session.id)
        if !shortModel.isEmpty { values.append(shortModel) }
        return values.joined(separator: " · ")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemBackground))
                Image(systemName: iconName)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(title)
                        .font(.system(size: 16, weight: unread ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if unread || session.running == true {
                        Circle()
                            .fill(session.running == true ? Color.accentColor : Color.green)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel(session.running == true ? "Running" : "Unread")
                    }
                    Spacer(minLength: 6)
                    if !updatedLabel.isEmpty {
                        Text(updatedLabel)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text(contextLabel)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// A real `TextField` keeps the keyboard and interactive dismissal semantics
/// native. Tapping the arrow hands the current draft to the full-screen New
/// Task sheet, where device/project/branch/mode/model/permission can be chosen.
private struct DSHRemoteTaskComposer: View {
    @Binding var text: String
    let modelLabel: String
    let onNewTask: () -> Void

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onNewTask) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New task")

            Divider()
                .frame(height: 24)
                .overlay(Color.primary.opacity(0.14))

            TextField("Plan, ask, build…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .lineLimit(1...3)
                .onSubmit {
                    if canSubmit { onNewTask() }
                }

            Spacer(minLength: 4)

            Menu {
                Text(modelLabel)
                    .font(.caption)
                Button { onNewTask() } label: {
                    Label("Choose model in new task", systemImage: "cpu")
                }
            } label: {
                Text(modelLabel)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button(action: onNewTask) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(canSubmit ? Color.accentColor : Color(.tertiarySystemBackground), in: Circle())
                    .foregroundStyle(canSubmit ? Color.white : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .accessibilityLabel("Start task")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.75)
        }
        .padding(.horizontal, 16)
        .padding(.top, 7)
        .padding(.bottom, 8)
        .background(Color(.systemBackground).opacity(0.94))
    }
}

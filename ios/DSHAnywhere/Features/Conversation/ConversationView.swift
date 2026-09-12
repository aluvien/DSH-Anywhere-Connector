import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ConversationView: View {
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: String

    @State private var showFileImporter = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showCommandMenu = false
    @State private var showModelPicker = false
    @State private var showPermissionPicker = false
    @State private var sentAttachmentIDs = Set<String>()
    @State private var didRefresh = false
    /// Tracks the composer field so the keyboard can be dismissed explicitly.
    @FocusState private var isDraftFocused: Bool

    private var session: DSHSessionSummary? { model.sessions.first { $0.id == sessionID } }
    private var isRunning: Bool { model.turnState(for: sessionID).lowercased() == "running" }
    private var pendingAttachments: [DSHUploadedAttachment] {
        model.attachments(for: sessionID).filter { !sentAttachmentIDs.contains($0.receiptId) }
    }
    /// A pending question or approval is a real request for input, so the
    /// "start a conversation" placeholder must not sit above it.
    private var hasBlockingInteraction: Bool {
        model.pendingApprovals.contains { $0.sessionId == sessionID }
            || model.pendingQuestions.contains { $0.sessionId == sessionID }
    }
    /// Assistant messages are grouped per turn so each turn folds its reasoning
    /// exactly once, below the answers it produced.
    private var transcriptBlocks: [DSHTranscriptBlock] {
        model.messages(for: sessionID).groupedIntoTranscriptBlocks()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(transcriptBlocks) { block in
                        if block.isUserTurn {
                            MessageBubble(message: block.messages[0]).id(block.id)
                        } else {
                            AssistantTurnView(block: block).id(block.id)
                        }
                    }
                    ForEach(model.tools(for: sessionID)) { tool in
                        ToolActivityCard(tool: tool)
                    }
                    ForEach(model.commandResults(for: sessionID)) { result in
                        CommandResultCard(result: result)
                    }
                    ForEach(model.pendingApprovals.filter { $0.sessionId == sessionID }) { approval in
                        ApprovalCard(approval: approval) { allow in
                            model.decide(approval, allow: allow)
                        }
                    }
                    ForEach(model.pendingQuestions.filter { $0.sessionId == sessionID }) { question in
                        QuestionCard(request: question) { answers in
                            model.answer(question, answers: answers)
                        }
                    }
                    if model.messages(for: sessionID).isEmpty, !hasBlockingInteraction {
                        ContentUnavailableView("Start a conversation", systemImage: "sparkles",
                                               description: Text("Send a prompt to your local DeepSeek Harness."))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            // Dragging the transcript puts the keyboard away, which is the
            // gesture people reach for after reading the latest reply.
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle(session?.title ?? "Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showModelPicker = true } label: {
                            Label("Select model", systemImage: "cpu")
                        }
                        Button { showPermissionPicker = true } label: {
                            Label("Permission", systemImage: "checkmark.shield")
                        }
                        Button { refreshSession() } label: {
                            Label("Refresh session info", systemImage: "arrow.clockwise")
                        }
                        Divider()
                        Button(role: .destructive) { archiveSession() } label: {
                            Label("Archive session", systemImage: "archivebox")
                        }
                    } label: {
                        Image(systemName: didRefresh ? "checkmark.circle.fill" : "ellipsis.circle")
                    }
                }
                // Swiping the transcript dismisses the keyboard, but a short
                // conversation has nothing to scroll, so keep an explicit exit.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isDraftFocused = false }
                }
            }
            .task(id: sessionID) {
                model.sendModelCatalog()
            }
            .onChange(of: model.messages(for: sessionID).count) { _, _ in
                if let id = model.messages(for: sessionID).last?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task { @MainActor in
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        model.uploadAttachment(name: "photo.jpg", data: data, for: sessionID)
                    }
                    selectedPhoto = nil
                }
            }
            .sheet(isPresented: $showCommandMenu) {
                CommandMenuSheet(
                    onCommand: { command in
                        showCommandMenu = false
                        if command == "permission" { showPermissionPicker = true }
                        else if command == "model" { showModelPicker = true }
                        else { model.executeCommand("/\(command)", for: sessionID) }
                    },
                    onDismiss: { showCommandMenu = false }
                )
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(sessionID: sessionID)
                    .environmentObject(model)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showPermissionPicker) {
                PermissionPickerSheet(sessionID: sessionID)
                    .environmentObject(model)
                    .presentationDetents([.medium])
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                for url in urls {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        model.uploadAttachment(name: url.lastPathComponent, data: data, for: sessionID)
                    }
                }
            }
        }
    }

    private var emptySession: DSHSessionSummary {
        DSHSessionSummary(id: sessionID, title: "Conversation")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            let attachments = pendingAttachments
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            Label(attachment.name, systemImage: "paperclip")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal)
                }
            }
            VStack(spacing: 8) {
                TextField("Send a message, / command, @ file or conversation", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .focused($isDraftFocused)
                    .onSubmit { send() }
                HStack(spacing: 10) {
                    Button { showCommandMenu = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                    .accessibilityLabel("Commands")
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Image(systemName: "paperclip").font(.title3)
                    }
                    .accessibilityLabel("Attach photo")
                    Button { showFileImporter = true } label: {
                        Image(systemName: "doc.badge.plus").font(.title3)
                    }
                    .accessibilityLabel("Attach file")
                    PermissionMenu(sessionID: sessionID)
                    Spacer()
                    ModelMenu(sessionID: sessionID)
                    if isRunning {
                        Button(action: { model.cancelTurn(for: sessionID) }) {
                            Image(systemName: "stop.fill").foregroundStyle(.red)
                        }
                        .accessibilityLabel("Stop turn")
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up.circle.fill").font(.title).foregroundStyle(.tint)
                        }
                        .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && pendingAttachments.isEmpty)
                        .accessibilityLabel("Send message")
                    }
                }
                UsageFooter(usage: model.usage(for: sessionID))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // No fill of its own: the composer already sits on the
            // `.ultraThinMaterial` band below, and stacking a second material
            // here is what made the card read as a redundant background behind
            // the text field. The stroke alone defines the card.
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.secondary.opacity(0.2)))
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        .background(.ultraThinMaterial)
    }

    private func send() {
        let receipts = pendingAttachments.map(\.receiptId)
        model.sendPrompt(model.draft, attachments: receipts, to: sessionID)
        sentAttachmentIDs.formUnion(receipts)
        model.draft = ""
    }

    private func refreshSession() {
        model.refreshSessions(includeArchived: true)
        model.sendModelCatalog()
        didRefresh = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didRefresh = false
        }
    }

    private func archiveSession() {
        model.archive(session ?? emptySession, archived: true)
        dismiss()
    }
}

private struct ModelMenu: View {
    @EnvironmentObject private var model: DSHAppModel
    let sessionID: String

    var body: some View {
        Menu {
            if let catalog = model.modelCatalog {
                ForEach(catalog.groups) { group in
                    Section(group.name) {
                        ForEach(group.models) { item in
                            Button {
                                let effort = item.reasoning?.defaultEffort
                                model.selectModel(DSHModelSelection(provider: group.id, model: item.id,
                                                                     reasoningEffort: effort), for: sessionID)
                            } label: {
                                Label(item.name, systemImage: "cpu")
                            }
                        }
                    }
                }
            } else {
                Button("Refresh models") { model.sendModelCatalog() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(model.modelDisplayName(for: sessionID)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.subheadline)
        }
        .accessibilityLabel("Model")
    }
}

private struct PermissionMenu: View {
    @EnvironmentObject private var model: DSHAppModel
    let sessionID: String

    var body: some View {
        Menu {
            ForEach(permissionModes, id: \.mode) { item in
                Button { model.setPermission(item.mode, for: sessionID) } label: {
                    Label(item.title, systemImage: model.permissionMode(for: sessionID) == item.mode ? "checkmark" : item.icon)
                }
            }
        } label: {
            Label(permissionLabel(model.permissionMode(for: sessionID)), systemImage: "checkmark.shield")
                .font(.subheadline)
        }
        .accessibilityLabel("Permission mode")
    }

    private func permissionLabel(_ value: String) -> String {
        switch value {
        case "ask": return "Ask"
        case "never": return "No approvals"
        case "read-only": return "Read only"
        case "danger-full-access": return "Full access"
        default: return "Workspace"
        }
    }

    private var permissionModes: [(mode: String, title: String, icon: String)] {
        [
            ("ask", "Ask every time", "questionmark.circle"),
            ("never", "Never ask", "checkmark.circle"),
            ("read-only", "Read only", "eye"),
            ("workspace-write", "Workspace changes", "folder"),
            ("danger-full-access", "Full access", "exclamationmark.triangle")
        ]
    }
}

/// Compact one-line usage strip. The previous 2×2 card grid plus a labelled
/// context bar consumed roughly five text lines directly above the composer;
/// this keeps the same numbers in a single row plus a hairline context bar.
private struct UsageFooter: View {
    let usage: DSHSessionUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                metric("gauge.with.dots.needle.67percent", activityText)
                separator
                metric("speedometer", speedText)
                separator
                metric("chart.bar.xaxis", tokenText)
                separator
                metric("externaldrive.badge.checkmark", cacheText)
                Spacer(minLength: 0)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            if let ratio = contextRatio {
                HStack(spacing: 6) {
                    ProgressView(value: ratio)
                        .progressViewStyle(.linear)
                        .tint(ratio > 0.9 ? .orange : .accentColor)
                        .frame(height: 2)
                    Text("\(Int(ratio * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var separator: some View {
        Text("·").foregroundStyle(.quaternary)
    }

    private func metric(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .medium))
            Text(text)
        }
    }

    private var contextRatio: Double? {
        guard let used = usage?.contextUsed, let window = usage?.contextWindow, window > 0 else { return nil }
        return min(1, max(0, used / window))
    }

    private var activityText: String {
        guard usage?.rounds != nil || usage?.steps != nil else { return "—" }
        return "\(usage?.rounds ?? 0)r/\(usage?.steps ?? 0)s"
    }

    private var speedText: String {
        guard let speed = usage?.tokensPerSecond else { return "—" }
        return "\(Int(speed)) tok/s"
    }

    private var tokenText: String {
        guard usage?.totalTokens != nil else { return "—" }
        return "\(compactNumber(usage?.totalTokens)) tok"
    }

    private var cacheText: String {
        guard let hit = usage?.cacheHitPercent else { return "—" }
        return "\(Int(hit))%"
    }

    private func compactNumber(_ value: Double?) -> String {
        guard let value else { return "0" }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return String(Int(value))
    }
}

private struct CommandMenuSheet: View {
    let onCommand: (String) -> Void
    let onDismiss: () -> Void

    private let commands: [(String, String, String)] = [
        ("compact", "压缩以上对话内容", "rectangle.compress.vertical"),
        ("export", "将当前会话导出为 ZIP", "square.and.arrow.up"),
        ("feedback", "发送关于当前会话的反馈", "bubble.left.and.exclamationmark.bubble.right"),
        ("goal", "设置或查看长期任务目标", "target"),
        ("permission", "切换权限预设（沙箱模式与审批策略）", "checkmark.shield"),
        ("plan", "进入或退出计划模式", "list.clipboard"),
        ("model", "选择本会话使用的模型", "cpu")
    ]

    var body: some View {
        NavigationStack {
            List(commands, id: \.0) { item in
                Button { onCommand(item.0) } label: {
                    Label { Text(item.1).foregroundStyle(.primary) } icon: {
                        Image(systemName: item.2).foregroundStyle(.tint)
                    }
                }
            }
            .navigationTitle("Commands")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done", action: onDismiss) }
            }
        }
    }
}

private struct ModelPickerSheet: View {
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: String

    var body: some View {
        NavigationStack {
            List {
                if let catalog = model.modelCatalog {
                    ForEach(catalog.groups) { group in
                        Section(group.name) {
                            ForEach(group.models) { item in
                                Button {
                                    model.selectModel(DSHModelSelection(provider: group.id, model: item.id,
                                                                         reasoningEffort: item.reasoning?.defaultEffort), for: sessionID)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name).foregroundStyle(.primary)
                                        if let description = item.description {
                                            Text(description).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No model catalog", systemImage: "cpu",
                                           description: Text("Reconnect to load available models."))
                }
            }
            .navigationTitle("Select model")
        }
    }
}

private struct PermissionPickerSheet: View {
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    private let modes: [(mode: String, title: String)] = [
        ("ask", "Ask every time"),
        ("never", "Never ask"),
        ("read-only", "Read only"),
        ("workspace-write", "Workspace changes"),
        ("danger-full-access", "Full access")
    ]

    var body: some View {
        NavigationStack {
            List(modes, id: \.mode) { item in
                Button {
                    model.setPermission(item.mode, for: sessionID)
                    dismiss()
                } label: {
                    HStack {
                        Text(item.title)
                        Spacer()
                        if model.permissionMode(for: sessionID) == item.mode { Image(systemName: "checkmark") }
                    }
                }
            }
            .navigationTitle("Permission")
        }
    }
}

private struct CommandResultCard: View {
    let result: DSHCommandResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(result.matched ? "Command completed" : "Command not found",
                  systemImage: result.matched ? "checkmark.circle" : "questionmark.circle")
                .font(.caption.weight(.semibold))
            if let text = result.text, !text.isEmpty {
                Text(text).font(.callout).textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct MessageBubble: View {
    let message: DSHChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 36) }
            messageText
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.12))
                .foregroundStyle(message.role == .user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            if message.role != .user { Spacer(minLength: 36) }
        }
    }

    @ViewBuilder private var messageText: some View {
        if let markdown = try? AttributedString(markdown: message.markdown) { Text(markdown) }
        else { Text(message.markdown) }
    }
}

/// One assistant turn: every answer it produced, then a single folded section
/// holding the whole turn's chain-of-thought. The transcript itself shows only
/// final results; the reasoning lives in that one collapsed space.
private struct AssistantTurnView: View {
    let block: DSHTranscriptBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(block.visibleMessages) { message in
                MessageBubble(message: message)
            }
            if !block.reasoning.isEmpty {
                ThinkingDisclosure(text: block.reasoning,
                                   answerCount: block.visibleMessages.count)
            }
        }
    }
}

/// Collapsed by default: one subdued row per turn. Expanding is capped in
/// height and scrolls, so a long chain-of-thought can never push the answers
/// off screen — the failure mode this replaced.
private struct ThinkingDisclosure: View {
    let text: String
    let answerCount: Int

    @State private var isExpanded = false

    private var title: String {
        isExpanded ? "Hide thinking" : "Thinking"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                    Text(title)
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide reasoning" : "Show reasoning")
            .accessibilityHint(answerCount > 1
                ? "Reasoning behind \(answerCount) answers in this turn"
                : "Reasoning behind this answer")

            if isExpanded {
                ScrollView {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
    }
}

struct ConversationView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack { ConversationView(sessionID: "preview-session") }
            .environmentObject(DSHAppModel.preview())
    }
}

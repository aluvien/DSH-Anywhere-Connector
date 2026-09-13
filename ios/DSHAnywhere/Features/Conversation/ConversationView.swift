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
    /// False once the reader scrolls away from the newest output, so auto-follow
    /// never fights a manual scroll.
    @State private var isFollowingLatest = true
    private static let bottomAnchor = "conversation-bottom"

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
    /// Messages and tool calls in one list, ordered by when they arrived.
    ///
    /// They used to render as two separate runs — every message, then every tool
    /// card — which stacked a turn's calls into one lump instead of showing the
    /// back-and-forth that actually happened.
    private var transcriptEntries: [DSHTranscriptEntry] {
        model.transcriptEntries(for: sessionID)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(transcriptEntries) { entry in
                        switch entry {
                        case .turn(let block):
                            if block.isUserTurn {
                                MessageBubble(message: block.messages[0]).id(entry.id)
                            } else {
                                AssistantTurnView(block: block).id(entry.id)
                            }
                        case .tool(let tool):
                            // Kept in place rather than hidden until a turn runs:
                            // popping them in and out is what made a new message
                            // look like it "suddenly" produced a wall of calls.
                            ToolActivityCard(tool: tool).id(entry.id)
                        }
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
                    // Tracks whether the viewport is at the newest output. It
                    // vanishes as soon as the reader scrolls back, which is what
                    // stops auto-follow from fighting a manual scroll.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                        .onAppear { isFollowingLatest = true }
                        .onDisappear { isFollowingLatest = false }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            // Dragging the transcript puts the keyboard away. `.always` keeps
            // the bounce gesture available even when a short conversation has
            // nothing to scroll, which is what the removed keyboard "Done" bar
            // was working around.
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.always)
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
            }
            .task(id: sessionID) {
                model.sendModelCatalog()
            }
            // Auto-follow only while the reader is already at the newest output.
            // Scrolling back disarms it, so incoming work never yanks the view.
            .onChange(of: model.messages(for: sessionID).count) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: transcriptEntries.count) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: isRunning) { _, _ in
                scrollToLatest(proxy)
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

    /// Input bar arranged like the reference app: the text field spans the full
    /// width on top, and every control lives in one row beneath it inside the
    /// same rounded container. The text is the primary thing; the controls
    /// gather under it instead of flanking it.
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
                                .background(.thinMaterial, in: .capsule)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }

            VStack(spacing: 8) {
                TextField("Send a message, / command, @ file or conversation",
                          text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .focused($isDraftFocused)
                    .onSubmit { send() }

                HStack(spacing: 10) {
                    // Icon per button must say what the button does: "/" for the
                    // slash commands, a picture for the photo picker, and the
                    // paperclip for files.
                    Button { showCommandMenu = true } label: {
                        Image(systemName: "slash.circle").font(.title3)
                    }
                    .accessibilityLabel("Commands")

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Image(systemName: "photo").font(.title3)
                    }
                    .accessibilityLabel("Attach photo")

                    Button { showFileImporter = true } label: {
                        Image(systemName: "paperclip").font(.title3)
                    }
                    .accessibilityLabel("Attach file")

                    PermissionMenu(sessionID: sessionID)

                    Spacer(minLength: 4)

                    ModelMenu(sessionID: sessionID)

                    if let ratio = contextRatio {
                        ContextRing(ratio: ratio)
                    }

                    if isRunning {
                        Button(action: { model.cancelTurn(for: sessionID) }) {
                            // The stock symbol, matching the send button's weight.
                            Image(systemName: "stop.circle.fill")
                                .font(.title)
                                .foregroundStyle(.red)
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))

            UsageFooter(usage: model.usage(for: sessionID))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Context window usage, shown as a ring beside the model.
    private var contextRatio: Double? {
        guard let usage = model.usage(for: sessionID),
              let used = usage.contextUsed, let window = usage.contextWindow, window > 0 else { return nil }
        return min(1, max(0, used / window))
    }

    /// Keeps the newest output on screen, unless the reader has scrolled away.
    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard isFollowingLatest else { return }
        withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
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

/// Context usage as a small ring. The old labelled bar took a whole line under
/// the composer for one number; a ring sits in the control row for free.
private struct ContextRing: View {
    let ratio: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.22), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: ratio)
                .stroke(ratio > 0.9 ? Color.orange : Color.accentColor,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
        .accessibilityLabel("Context \(Int(ratio * 100)) percent used")
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
                // Only the model itself, not "provider/model": the provider is
                // the same across the catalogue and pushed the useful part into
                // an ellipsis.
                Text(model.shortModelName(for: sessionID))
                    .lineLimit(1)
                    .truncationMode(.middle)
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
            // Icon only: the label cost ~80pt of a row that also holds three
            // attachments, the model and send. The mode is still announced.
            Image(systemName: "checkmark.shield")
                .font(.title3)
        }
        .accessibilityLabel("Permission: \(permissionLabel(model.permissionMode(for: sessionID)))")
        .accessibilityHint("Changes the sandbox and approval policy for this session")
    }

    /// The Harness persists a preset as sandbox mode + approval policy, so a
    /// session can report a raw sandbox mode rather than a preset name.
    private func permissionLabel(_ value: String) -> String {
        switch value {
        case "danger-full-access": return DSHLocalization.string("Full access")
        case "workspace-write": return DSHLocalization.string("Workspace write")
        // read-only and ask arrive from sessions configured outside the app.
        case "read-only": return DSHLocalization.string("Read only")
        case "ask": return DSHLocalization.string("Ask")
        default: return DSHLocalization.string("Workspace write")
        }
    }

    /// Exactly the presets the Harness defines, and no more.
    ///
    /// Each preset is a sandbox mode *plus* an approval policy. The picker used
    /// to offer five entries that mixed the two concepts ("ask", "never",
    /// "read-only"), and the Harness rejects anything outside this pair with
    /// 400 — so three of the five could never take effect.
    private var permissionModes: [(mode: String, title: String, icon: String)] {
        // Titles are localized here rather than left to `Label`, which only
        // localizes a literal and takes this value as a plain String.
        [
            ("workspace-write", DSHLocalization.string("Workspace write"), "folder"),
            ("danger-full-access", DSHLocalization.string("Full access"), "exclamationmark.triangle")
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
            }
            // Centred rather than left-aligned: the composer is a narrow band on
            // a phone, so a centred row reads as a balanced footer under it.
            .frame(maxWidth: .infinity, alignment: .center)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)

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
        // Two decimals, rounded rather than truncated. The integer form this
        // replaced made 99.0 and 99.9 identical — exactly the range where cache
        // behaviour matters. Note the resolution behind the second decimal
        // depends on session size: at ~700K tokens one step of 0.01% is roughly
        // 7,000 tokens, so in a large session it will rarely move.
        return String(format: "%.2f%%", hit)
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
                    Label {
                        // Show the literal command the row runs, so the sheet
                        // teaches the slash syntax instead of only describing it:
                        // icon, "/command", a space, then the Chinese gloss.
                        HStack(spacing: 0) {
                            Text("/\(item.0)")
                                .font(.body.monospaced())
                                .foregroundStyle(.tint)
                            Text(" \(item.1)")
                                .foregroundStyle(.primary)
                        }
                    } icon: {
                        Image(systemName: item.2).foregroundStyle(.tint)
                    }
                }
                .accessibilityLabel("/\(item.0) \(item.1)")
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
        MarkdownBlockText(text: message.markdown)
    }
}

/// Renders markdown block by block.
///
/// `AttributedString(markdown:)` interprets inline syntax only, so headings,
/// fenced code, lists and tables reached the reader as their literal markers —
/// `#`, ``` ``` ``` and `|` included. Block structure is recognised first
/// (`DSHMarkdown`), then each block is styled; inline markup inside a block is
/// still left to `AttributedString`.
private struct MarkdownBlockText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(DSHMarkdown.blocks(from: text)) { block in
                MarkdownBlockView(block: block)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: DSHMarkdownBlock

    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            inline(text)
                .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 2)

        case .paragraph(let text):
            inline(text)

        case .code(let language, let body):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                // Code keeps its own line breaks, so it scrolls sideways instead
                // of wrapping into an unreadable column.
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(body)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 10))

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inline(item)
                    }
                }
            }

        case .numbers(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                        inline(item)
                    }
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                inline(text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .table(let header, let rows):
            MarkdownTableView(header: header, rows: rows)

        case .divider:
            Divider()
        }
    }

    private func inline(_ text: String) -> Text {
        // Preserving whitespace keeps an authored line break inside a paragraph
        // instead of collapsing the block onto one line.
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }
}

/// A markdown table, kept rectangular so columns line up even when a row is
/// short, and scrollable because a wide table cannot wrap usefully.
private struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    private var columns: Int { max(header.count, 1) }

    private func padded(_ row: [String]) -> [String] {
        row.count >= columns
            ? Array(row.prefix(columns))
            : row + Array(repeating: "", count: columns - row.count)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        inline(cell).font(.caption.weight(.semibold))
                    }
                }
                Divider().gridCellColumns(columns)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(padded(row).enumerated()), id: \.offset) { _, cell in
                            inline(cell).font(.caption)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 10))
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
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

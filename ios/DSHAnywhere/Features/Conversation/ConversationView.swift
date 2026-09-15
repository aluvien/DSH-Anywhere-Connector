import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import UIKit

struct DSHStagedAttachment: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let data: Data
    let isImage: Bool
}

/// Shared compact composer chrome used by both an existing conversation and
/// the new-session screen. The caller owns the whole control row so collapsing
/// it can replace *only* command/photo/file with a plus menu. Permission,
/// model, context and send/stop controls therefore stay byte-for-byte the same
/// as the expanded editor instead of drifting into a second visual language.
struct DSHCompactComposer<Controls: View>: View {
    @Binding var text: String
    let placeholder: String
    let hasAttachments: Bool
    let onSubmit: () -> Void
    let controls: Controls
    @FocusState private var isFocused: Bool

    init(text: Binding<String>,
         placeholder: String,
         hasAttachments: Bool = false,
         onSubmit: @escaping () -> Void,
         @ViewBuilder controls: () -> Controls) {
        _text = text
        self.placeholder = placeholder
        self.hasAttachments = hasAttachments
        self.onSubmit = onSubmit
        self.controls = controls()
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($isFocused)
                .onSubmit {
                    if canSubmit { onSubmit() }
                }

            HStack(spacing: 10) {
                controls
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
    }
}

/// A native anchored menu, deliberately not a sheet/card. These are the only
/// three controls hidden by the compact-editor preference.
struct DSHComposerQuickActionsMenu: View {
    let onCommand: () -> Void
    let onPhoto: () -> Void
    let onFile: () -> Void

    var body: some View {
        Menu {
            Button(action: onCommand) {
                Label("Commands", systemImage: "slash.circle")
            }
            Button(action: onPhoto) {
                Label("Attach photo", systemImage: "photo")
            }
            Button(action: onFile) {
                Label("Attach file", systemImage: "paperclip")
            }
        } label: {
            Image(systemName: "plus")
                .font(.title3)
        }
        .accessibilityLabel("More actions")
    }
}

struct ConversationView: View {
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: String

    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showCommandMenu = false
    @State private var showModelPicker = false
    @State private var showPermissionPicker = false
    /// Attachments stay entirely local while the composer is being edited.
    /// They are uploaded only from `send()`, after the user has confirmed the
    /// whole prompt, so cancelling/removing a chip never leaves a remote file.
    @State private var draftAttachments: [DSHStagedAttachment] = []
    @State private var isSending = false
    @State private var didRefresh = false
    /// Tracks the composer field so the keyboard can be dismissed explicitly.
    @FocusState private var isDraftFocused: Bool
    /// False once the reader scrolls away from the newest output, so auto-follow
    /// never fights a manual scroll.
    @State private var isFollowingLatest = true
    private static let bottomAnchor = "conversation-bottom"

    private var session: DSHSessionSummary? { model.sessions.first { $0.id == sessionID } }
    private var isRunning: Bool { model.turnState(for: sessionID).lowercased() == "running" }
    private var hasDraftAttachments: Bool { !draftAttachments.isEmpty }
    private var hasRenderedContent: Bool {
        !transcriptEntries.isEmpty
            || !model.commandResults(for: sessionID).isEmpty
            || model.pendingApprovals.contains { $0.sessionId == sessionID }
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

    /// Streaming deltas replace the last message's value in place, so the
    /// array count does not change while an answer is being generated.  Keep a
    /// small, cheap signature of the newest message to make SwiftUI observe
    /// those in-place edits and follow the live output without hashing the
    /// entire transcript on every token.
    private var latestStreamingSignature: String {
        guard let message = model.messages(for: sessionID).last else { return "" }
        let markdownTail = String(message.markdown.suffix(64))
        let reasoning = message.reasoning ?? ""
        let reasoningTail = String(reasoning.suffix(64))
        return "\(message.id)|\(message.markdown.count)|\(markdownTail)|\(reasoning.count)|\(reasoningTail)"
    }

    private var conversationTitle: String {
        let value = session?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? DSHLocalization.string("New session") : value
    }

    private var conversationSubtitle: String {
        if let workspace = session?.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines), !workspace.isEmpty {
            return workspace
        }
        if let cwd = session?.cwd, let last = cwd.split(separator: "/").last, !last.isEmpty {
            return String(last)
        }
        return "DSH Anywhere"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(transcriptEntries) { entry in
                        switch entry {
                        case .turn(let block):
                            if block.isUserTurn {
                                MessageBubble(sessionID: sessionID, message: block.messages[0]).id(entry.id)
                            } else {
                                AssistantTurnView(sessionID: sessionID, block: block).id(entry.id)
                            }
                        case .tool(let tool):
                            // Kept in place rather than hidden until a turn runs:
                            // popping them in and out is what made a new message
                            // look like it "suddenly" produced a wall of calls.
                            ToolActivityCard(tool: tool).id(entry.id)
                        case .command(let result):
                            CommandResultCard(result: result).id(entry.id)
                        case .modelChange(let notice):
                            ModelChangeCard(notice: notice).id(entry.id)
                        }
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
                    if !hasRenderedContent {
                        emptyConversationState
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
            .background(Color(.systemBackground))
            .refreshable {
                // Remote's pull-to-refresh rehydrates both the task metadata
                // and the durable transcript without creating a second socket
                // or replaying the whole event stream.
                model.refreshSessions(includeArchived: true)
                model.sendModelCatalog()
                model.openSession(sessionID)
            }
            // Dragging the transcript puts the keyboard away. `.always` keeps
            // the bounce gesture available even when a short conversation has
            // nothing to scroll, which is what the removed keyboard "Done" bar
            // was working around.
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.always)
            .safeAreaInset(edge: .bottom) { composer }
            // Only while the reader is away from the newest output: the whole
            // point is to not need this button when already at the bottom.
            .overlay(alignment: .bottomTrailing) {
                if !isFollowingLatest {
                    Button {
                        isFollowingLatest = true
                        withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(radius: 3, y: 1)
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .accessibilityLabel("Jump to latest output")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { happyConversationHeader }
            .toolbar(.hidden, for: .navigationBar)
            // The custom Happy header intentionally hides SwiftUI's navigation
            // bar. Re-enable UIKit's native edge-swipe pop gesture so the
            // conversation still behaves like a normal NavigationStack page.
            .background(DSHInteractivePopGestureEnabler())
            .task(id: sessionID) {
                model.markSessionRead(sessionID)
                model.sendModelCatalog()
                model.openSession(sessionID)
            }
            // Auto-follow only while the reader is already at the newest output.
            // Scrolling back disarms it, so incoming work never yanks the view.
            .onChange(of: model.messages(for: sessionID).count) { _, _ in
                model.markSessionRead(sessionID)
                scrollToLatest(proxy)
            }
            .onChange(of: session?.updatedAt) { _, _ in
                model.markSessionRead(sessionID)
            }
            .onChange(of: transcriptEntries.count) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: latestStreamingSignature) { _, _ in
                // Assistant deltas mutate the current message instead of
                // appending a new one.  This observer keeps a reader at the
                // bottom during a live answer while `scrollToLatest` still
                // respects the manual-scroll guard above.
                scrollToLatest(proxy)
            }
            .onChange(of: isRunning) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                // Both the expanded photo button and compact plus menu use the
                // same staging path, so selection never uploads immediately.
                Task { @MainActor in
                    defer { selectedPhoto = nil }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            reportPhotoFailure()
                            return
                        }
                        // JPEG/downsampling is CPU work. Keep it off the main
                        // actor so choosing a large iCloud photo does not make
                        // the composer freeze before the user can press Send.
                        let optimized = await optimizedPhotoDataOffMain(data)
                        draftAttachments.append(DSHStagedAttachment(name: "photo.jpg",
                                                                    data: optimized,
                                                                    isImage: true))
                    } catch {
                        // `try?` used to swallow this, so a failure looked like
                        // the button doing nothing at all.
                        reportPhotoFailure()
                    }
                }
            }
            .sheet(isPresented: $showCommandMenu) {
                CommandMenuSheet(
                    selectedPhoto: $selectedPhoto,
                    onFile: {
                        showCommandMenu = false
                        showFileImporter = true
                    },
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
            .photosPicker(isPresented: $showPhotoPicker,
                          selection: $selectedPhoto,
                          matching: .images)
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                for url in urls {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        draftAttachments.append(DSHStagedAttachment(name: url.lastPathComponent,
                                                                   data: data,
                                                                   isImage: url.pathExtension.lowercased() == "png"
                                                                    || url.pathExtension.lowercased() == "jpg"
                                                                    || url.pathExtension.lowercased() == "jpeg"
                                                                    || url.pathExtension.lowercased() == "heic"))
                    }
                }
            }
        }
    }

    /// Remote's task header is intentionally quiet: the title and project are
    /// presented as one centred capsule, with the back control on the left and
    /// the project mark/options control on the right. This is the same visual
    /// hierarchy as the Remote task detail screen; connection status remains
    /// in the composer status row below the transcript.
    private var happyConversationHeader: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(conversationTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(conversationSubtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.75) }
            .allowsHitTesting(false)

            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay { Circle().stroke(Color.primary.opacity(0.14), lineWidth: 0.75) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                Spacer(minLength: 0)

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
                    DSHHappyAvatar(size: 44)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Session settings")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Color(.systemBackground).opacity(0.96))
    }

    /// Happy's empty conversation state is intentionally sparse: a laptop,
    /// machine/path, and two centred lines.  It leaves the lower third clear
    /// for the status row and composer instead of putting a large card there.
    private var emptyConversationState: some View {
        let machine = model.machineName.isEmpty ? "Mac" : model.machineName
        let path = session?.cwd.map(Self.displayPath) ?? conversationSubtitle
        return VStack(spacing: 0) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 72, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)

            Text(machine)
                .font(.system(size: 22, weight: .semibold))
                .padding(.bottom, 4)

            Text(path)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 28)
                .padding(.bottom, 40)

            Text("No messages yet")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            Text("Created just now")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 500)
        .multilineTextAlignment(.center)
    }

    private static func displayPath(_ raw: String) -> String {
        // The path belongs to the Mac, while this code runs in the iOS
        // sandbox (whose FileManager home is unrelated).  Collapse the
        // conventional `/Users/<name>` prefix without trying to read the Mac's
        // filesystem from the phone.
        let components = raw.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0] == "Users" else { return raw }
        let suffix = components.dropFirst(2).joined(separator: "/")
        return suffix.isEmpty ? "~" : "~/\(suffix)"
    }

    private var emptySession: DSHSessionSummary {
        DSHSessionSummary(id: sessionID, title: "Conversation")
    }

    /// Input bar arranged like the reference app.  A brand-new session uses
    /// Happy's quiet two-line card; once the user types or attaches something,
    /// the controls expand to expose commands, attachments, permissions and
    /// model selection without changing the send path.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !draftAttachments.isEmpty {
                draftAttachmentStrip
            }

            // Keep reachability and branch visible while reading a running
            // conversation too.  The original implementation hid this row
            // as soon as the first transcript entry arrived, which made the
            // status jump above the composer and left no persistent context.
            sessionStatusBar

            if model.collapseComposerControls {
                compactComposer
            } else {
                expandedComposer
            }

            if hasRenderedContent && model.showUsageFooter {
                UsageFooter(usage: model.usage(for: sessionID))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var draftAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(draftAttachments) { attachment in
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
                            draftAttachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove attachment")
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

    /// The two small labels above Happy's empty-session composer: machine
    /// reachability on the left and the current branch on the right.
    private var sessionStatusBar: some View {
        let branch: String
        if let value = session?.branch?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            branch = value
        } else {
            branch = "main"
        }
        return HStack {
            HStack(spacing: 5) {
                Circle()
                    .fill(deviceStatusColor)
                    .frame(width: 7, height: 7)
                Text(deviceStatusLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(deviceStatusColor)
            }

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .medium))
                Text(branch)
                    .font(.system(size: 13, weight: .regular))
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 1)
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
        case .error: return DSHLocalization.string("Error")
        case .online: return DSHLocalization.string("Online")
        case .approvalRequired: return DSHLocalization.string("Permission confirmation required")
        }
    }

    /// Resting composer geometry: 44pt controls, a 24pt rounded card and no
    /// extra usage line.  The plus button exposes only command/photo/file;
    /// the permission, model and send controls remain in this same editor.
    private var compactComposer: some View {
        DSHCompactComposer(text: $model.draft,
                           placeholder: DSHLocalization.string("Send a message, / command, @ file or conversation"),
                           hasAttachments: hasDraftAttachments,
                           onSubmit: send) {
            DSHComposerQuickActionsMenu(
                onCommand: { showCommandMenu = true },
                onPhoto: { showPhotoPicker = true },
                onFile: { showFileImporter = true }
            )

            PermissionMenu(sessionID: sessionID, compact: true)

            Spacer(minLength: 4)

            ModelMenu(sessionID: sessionID)

            ReasoningEffortMenu(sessionID: sessionID)

            if let ratio = contextRatio {
                ContextRing(ratio: ratio)
            }

            composerSendControl
        }
    }

    private var expandedComposer: some View {
        VStack(spacing: 8) {
            TextField("Send a message, / command, @ file or conversation",
                      text: $model.draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($isDraftFocused)
                .onSubmit { send() }

            HStack(spacing: 10) {
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

                ReasoningEffortMenu(sessionID: sessionID)

                if let ratio = contextRatio {
                    ContextRing(ratio: ratio)
                }

                composerSendControl
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
    }

    @ViewBuilder private var composerSendControl: some View {
        if isSending {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Sending")
        } else if isRunning {
            Button(action: { model.cancelTurn(for: sessionID) }) {
                Image(systemName: "stop.circle.fill")
                    .font(.title)
                    .foregroundStyle(.red)
            }
            .accessibilityLabel("Stop turn")
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
            }
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !hasDraftAttachments)
            .accessibilityLabel("Send message")
        }
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
        // Streaming deltas are intentionally not animated. The old
        // `withAnimation` ran once per token and kept Core Animation busy even
        // when the reader was already at the bottom, which made the phone warm
        // and caused visible stutter. The explicit jump button below still uses
        // an animation when the user asks for one.
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    private func send() {
        guard !isSending else { return }
        let text = model.draft
        let staged = draftAttachments
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !staged.isEmpty else { return }

        // Clear the editor immediately so a double tap cannot send the same
        // draft twice. If an upload fails, restore the not-yet-uploaded chips
        // below so the user can retry without selecting the files again.
        model.draft = ""
        draftAttachments = []
        isSending = true
        Task { @MainActor in
            var uploadedCount = 0
            do {
                var receipts: [String] = []
                var messageAttachments: [DSHMessageAttachment] = []
                receipts.reserveCapacity(staged.count)
                for attachment in staged {
                    let receipt = try await model.uploadAttachmentAndWait(name: attachment.name,
                                                                           data: attachment.data,
                                                                           for: sessionID)
                    receipts.append(receipt)
                    let mediaType = attachment.isImage ? "image/jpeg" : nil
                    model.cacheAttachmentData(attachment.data, for: receipt)
                    messageAttachments.append(DSHMessageAttachment(id: receipt,
                                                                    name: attachment.name,
                                                                    mediaType: mediaType,
                                                                    receiptId: receipt))
                    uploadedCount += 1
                }
                model.sendPrompt(text, attachments: receipts,
                                 messageAttachments: messageAttachments, to: sessionID)
            } catch {
                model.draft = text
                draftAttachments = Array(staged.dropFirst(uploadedCount))
                model.errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }

    /// A photo that is only in iCloud cannot be read without downloading it
    /// first, and the picker gives no hint of that — so say it.
    private func reportPhotoFailure() {
        model.errorMessage = DSHLocalization.string(
            "Could not read that photo. If it is stored in iCloud, open it in Photos once so it downloads, then try again.")
    }

    private func refreshSession() {
        model.refreshSessions(includeArchived: true)
        model.sendModelCatalog()
        model.openSession(sessionID)
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

/// Restores the native UINavigationController interactive-pop gesture after a
/// screen supplies its own navigation chrome. A transparent child controller
/// reaches the NavigationStack's UIKit host without replacing navigation or
/// emulating the gesture with a competing DragGesture over the transcript.
private struct DSHInteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> HostController {
        HostController(coordinator: context.coordinator)
    }

    func updateUIViewController(_ controller: HostController, context: Context) {
        controller.coordinator = context.coordinator
        controller.attachIfPossible()
    }

    static func dismantleUIViewController(_ controller: HostController, coordinator: Coordinator) {
        coordinator.restore()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?
        weak var previousDelegate: UIGestureRecognizerDelegate?

        func attach(to navigationController: UINavigationController) {
            guard self.navigationController !== navigationController else {
                navigationController.interactivePopGestureRecognizer?.isEnabled = true
                return
            }
            restore()
            self.navigationController = navigationController
            let gesture = navigationController.interactivePopGestureRecognizer
            previousDelegate = gesture?.delegate
            gesture?.delegate = self
            gesture?.isEnabled = true
        }

        func restore() {
            guard let navigationController,
                  let gesture = navigationController.interactivePopGestureRecognizer,
                  gesture.delegate === self else { return }
            gesture.delegate = previousDelegate
            gesture.isEnabled = true
            self.navigationController = nil
            previousDelegate = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigationController,
                  navigationController.viewControllers.count > 1,
                  navigationController.presentedViewController == nil else { return false }
            return true
        }
    }

    final class HostController: UIViewController {
        var coordinator: Coordinator

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attachIfPossible()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            attachIfPossible()
        }

        func attachIfPossible() {
            guard let navigationController else { return }
            coordinator.attach(to: navigationController)
        }
    }
}

/// Camera-library originals can be 10–30 MB. Downsample them before putting
/// them into a JSON/WebSocket command so the phone does not retain a giant
/// decoded bitmap or hit the Connector's upload deadline.
private func optimizedPhotoData(_ data: Data) -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 2048
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return data
    }
    return UIImage(cgImage: image).jpegData(compressionQuality: 0.82) ?? data
}

func optimizedPhotoDataOffMain(_ data: Data) async -> Data {
    await Task.detached(priority: .userInitiated) {
        optimizedPhotoData(data)
    }.value
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
    let compact: Bool

    init(sessionID: String, compact: Bool = false) {
        self.sessionID = sessionID
        self.compact = compact
    }

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
            HStack(spacing: compact ? 5 : 4) {
                if !compact { Image(systemName: "cpu") }
                Text(displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.78)
                if !compact {
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
            .font(.system(size: compact ? 15 : 14, weight: .regular))
        }
        .accessibilityLabel("Model")
    }

    private var displayName: String {
        let base = model.shortModelName(for: sessionID)
        guard compact,
              let effort = model.sessions.first(where: { $0.id == sessionID })?.reasoningEffort,
              !effort.isEmpty else { return base }
        return "\(base) · \(effort.capitalized)"
    }
}

/// A separate selector placed immediately after the model name. The menu is
/// absent when the live Harness catalog says the model has no effort choices.
private struct ReasoningEffortMenu: View {
    @EnvironmentObject private var model: DSHAppModel
    let sessionID: String

    var body: some View {
        if let configuration = model.reasoningConfiguration(for: sessionID) {
            Menu {
                ForEach(configuration.efforts) { effort in
                    Button {
                        model.selectModel(
                            DSHModelSelection(provider: configuration.provider,
                                              model: configuration.model,
                                              reasoningEffort: effort.id),
                            for: sessionID
                        )
                    } label: {
                        Label(effort.name,
                              systemImage: effort.id == configuration.selectedEffortID
                                ? "checkmark" : "brain.head.profile")
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(configuration.selectedEffort?.name ?? configuration.selectedEffortID)
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
}

private struct PermissionMenu: View {
    @EnvironmentObject private var model: DSHAppModel
    let sessionID: String
    let compact: Bool

    init(sessionID: String, compact: Bool = false) {
        self.sessionID = sessionID
        self.compact = compact
    }

    var body: some View {
        Menu {
            ForEach(permissionModes, id: \.mode) { item in
                Button { model.setPermission(item.mode, for: sessionID) } label: {
                    Label(item.title, systemImage: model.permissionMode(for: sessionID) == item.mode ? "checkmark" : item.icon)
                }
            }
        } label: {
            if compact {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.shield")
                        .font(.title3)
                    Text(permissionLabel(model.permissionMode(for: sessionID)))
                        .font(.system(size: 14, weight: .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            } else {
                // Icon only: the label cost ~80pt of a row that also holds
                // three attachments, the model and send. The mode is still
                // announced.
                Image(systemName: "checkmark.shield")
                    .font(.title3)
            }
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

    /// The three user-facing permission presets map directly to Harness
    /// sandbox choices. Legacy ask/never values remain readable in the store
    /// but are intentionally not offered as separate modes here.
    private var permissionModes: [(mode: String, title: String, icon: String)] {
        // Titles are localized here rather than left to `Label`, which only
        // localizes a literal and takes this value as a plain String.
        [
            ("read-only", "仅可查看", "eye"),
            ("workspace-write", DSHLocalization.string("Workspace write"), "folder"),
            ("danger-full-access", "完全权限", "exclamationmark.triangle")
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

struct CommandMenuSheet: View {
    @Binding var selectedPhoto: PhotosPickerItem?
    let onFile: () -> Void
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
            List {
                Section("Attachments") {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Photo", systemImage: "photo")
                    }
                    Button(action: onFile) {
                        Label("File", systemImage: "paperclip")
                    }
                }
                Section("Commands") {
                    ForEach(commands, id: \.0) { item in
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
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .top, spacing: 0) {
                HappySheetHeader(title: "Commands", onClose: onDismiss,
                                 trailingTitle: "Done", trailingAction: onDismiss)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: selectedPhoto) { _, item in
                if item != nil { onDismiss() }
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
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .top, spacing: 0) {
                HappySheetHeader(title: "Select model", onClose: { dismiss() })
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct PermissionPickerSheet: View {
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    private let modes: [(mode: String, title: String)] = [
        ("read-only", "仅可查看"),
        ("workspace-write", "工作区内修改"),
        ("danger-full-access", "完全权限")
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
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .top, spacing: 0) {
                HappySheetHeader(title: "Permission", onClose: { dismiss() })
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// Shared 44pt sheet chrome for command, model and permission pickers. Keeping
/// the close target in the same place prevents each modal from feeling like a
/// different mini-app when it slides over the conversation screen.
private struct HappySheetHeader: View {
    let title: String
    let onClose: () -> Void
    var trailingTitle: String?
    var trailingAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay { Circle().stroke(Color.primary.opacity(0.14), lineWidth: 0.75) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)

            if let trailingTitle, let trailingAction {
                Button(trailingTitle, action: trailingAction)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(minWidth: 52, minHeight: 44)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            } else {
                Color.clear.frame(width: 52, height: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Color(.systemBackground).opacity(0.96))
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

/// Inline, non-avatar system event used when a running session changes its
/// model. It lives in the transcript sequence, so it scrolls with the answer
/// that follows instead of becoming a permanent footer card.
private struct ModelChangeCard: View {
    let notice: DSHModelChangeNotice

    private var fromLabel: String {
        guard let previous = notice.previous else { return "初始模型" }
        return compact(previous)
    }

    private var toLabel: String { compact(notice.current) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("模型已切换")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(fromLabel) → \(toLabel)")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Self.timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(notice.timestamp) / 1_000)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("模型已切换：\(fromLabel) 到 \(toLabel)")
    }

    private func compact(_ selection: DSHModelSelection) -> String {
        let value = selection.model
        let lowered = "\(selection.provider)/\(value)".lowercased()
        if lowered.contains("deepseek") {
            if lowered.contains("v4.1") && lowered.contains("flash") { return "DS V4.1F" }
            if lowered.contains("v4.1") && (lowered.contains("reason") || lowered.contains("r1")) { return "DS V4.1R" }
            if lowered.contains("v4.1") { return "DS V4.1" }
        }
        if lowered.contains("claude") {
            if lowered.contains("opus") { return "Claude Opus" }
            if lowered.contains("sonnet") { return "Claude Sonnet" }
        }
        return value
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct MessageBubble: View {
    @EnvironmentObject private var model: DSHAppModel
    let sessionID: String
    let message: DSHChatMessage
    @State private var showActions = false
    @State private var showDeleteConfirmation = false
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if message.role == .user { Spacer(minLength: 36) }
                messageContent
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.12))
                    .foregroundStyle(message.role == .user ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showActions = true
                        }
                    }
                if message.role != .user { Spacer(minLength: 36) }
            }

            if model.showMessageActionsByDefault || showActions {
                HStack(spacing: 12) {
                    if message.role == .user { Spacer(minLength: 36) }

                    Button(action: copyMessage) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .frame(width: 28, height: 24)
                    }
                    .accessibilityLabel(didCopy ? "Copied" : "Copy")

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 28, height: 24)
                    }
                    .accessibilityLabel("Delete")

                    if message.role != .user { Spacer(minLength: 36) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .confirmationDialog("Delete this message?",
                            isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.hideMessage(message.id, in: sessionID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the message from this iPhone only. The original Harness history on your Mac is unchanged.")
        }
    }

    private func copyMessage() {
        let attachmentLines = message.attachments.map { "📎 \($0.name)" }
        let value = ([message.markdown] + attachmentLines)
            .filter { !$0.isEmpty }
            .joined(separator: message.markdown.isEmpty ? "\n" : "\n\n")
        UIPasteboard.general.string = value
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }

    @ViewBuilder private var messageContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.attachments.isEmpty {
                MessageAttachmentsView(attachments: message.attachments)
            }
            if !message.markdown.isEmpty {
                MarkdownBlockText(text: message.markdown)
                    // Long-press to select and copy a reply.
                    .textSelection(.enabled)
            }
        }
    }
}

private struct MessageAttachmentsView: View {
    let attachments: [DSHMessageAttachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                MessageAttachmentPreview(attachment: attachment)
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
    }
}

private struct MessageAttachmentPreview: View {
    @EnvironmentObject private var model: DSHAppModel
    let attachment: DSHMessageAttachment
    @State private var data: Data?

    var body: some View {
        Group {
            if attachment.isImage, let data, let image = UIImage(data: data) {
                VStack(alignment: .leading, spacing: 4) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text(attachment.name)
                        .font(.caption2)
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: attachment.isImage ? "photo" : "paperclip")
                        .font(.caption.weight(.semibold))
                    Text(attachment.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: attachment.id) {
            data = model.attachmentData(for: attachment)
        }
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
    @State private var copied = false

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
                HStack {
                    if let language, !language.isEmpty {
                        Text(language)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    // Copying a fence by hand means selecting across a
                    // horizontally scrolling view, which iOS makes painful.
                    Button {
                        UIPasteboard.general.string = body
                        copied = true
                    } label: {
                        // A ternary is a String, not a literal, so `Label`
                        // would not localize it.
                        Label(copied ? DSHLocalization.string("Copied") : DSHLocalization.string("Copy"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(copied
                        ? DSHLocalization.string("Code copied")
                        : DSHLocalization.string("Copy code"))
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
            .onChange(of: copied) { _, isCopied in
                guard isCopied else { return }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }

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
    @EnvironmentObject private var model: DSHAppModel
    let sessionID: String
    let block: DSHTranscriptBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(block.visibleMessages) { message in
                MessageBubble(sessionID: sessionID, message: message)
            }
            if !block.reasoning.isEmpty {
                ThinkingDisclosure(text: block.reasoning,
                                   answerCount: block.visibleMessages.count,
                                   usage: block.visibleMessages.last?.usage,
                                   showUsage: model.showTurnUsage)
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
    let usage: DSHSessionUsage?
    let showUsage: Bool

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
                    if showUsage, let usage {
                        Text(turnStats(usage))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
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

    private func turnStats(_ usage: DSHSessionUsage) -> String {
        let input = usage.inputTokens ?? 0
        let output = usage.outputTokens ?? 0
        if input == 0 && output == 0 { return "" }
        return "\(compact(input + output)) tok"
    }

    private func compact(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return String(Int(value))
    }
}

struct ConversationView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack { ConversationView(sessionID: "preview-session") }
            .environmentObject(DSHAppModel.preview())
    }
}

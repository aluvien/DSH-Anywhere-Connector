import SwiftUI
import Combine
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

private extension URL {
    /// Image extensions the composer treats as previewable photos.
    var isImageFile: Bool {
        ["png", "jpg", "jpeg", "heic"].contains(pathExtension.lowercased())
    }
}


/// Remote's editor has two native-looking states: a quiet single-line capsule
/// while resting, and a taller two-row editor while the field is active.  The
/// same component is shared by conversations and the new-task screen so their
/// geometry and icon order cannot drift apart.
struct DSHRemoteComposer<Leading: View, Configuration: View, Submit: View>: View {
    @Binding var text: String
    let placeholder: String
    let hasAttachments: Bool
    let autofocus: Bool
    let showsMicrophone: Bool
    let onSubmit: () -> Void
    let slashCommands: [(id: String, gloss: String, icon: String)]
    let onSlashCommand: ((String) -> Void)?
    let leading: Leading
    let configuration: Configuration
    let submit: Submit
    @FocusState private var isFocused: Bool

    init(text: Binding<String>,
         placeholder: String,
         hasAttachments: Bool = false,
         autofocus: Bool = false,
         showsMicrophone: Bool = true,
         onSubmit: @escaping () -> Void,
         slashCommands: [(id: String, gloss: String, icon: String)] = [],
         onSlashCommand: ((String) -> Void)? = nil,
         @ViewBuilder leading: () -> Leading,
         @ViewBuilder configuration: () -> Configuration,
         @ViewBuilder submit: () -> Submit) {
        _text = text
        self.placeholder = placeholder
        self.hasAttachments = hasAttachments
        self.autofocus = autofocus
        self.showsMicrophone = showsMicrophone
        self.onSubmit = onSubmit
        self.slashCommands = slashCommands
        self.onSlashCommand = onSlashCommand
        self.leading = leading()
        self.configuration = configuration()
        self.submit = submit()
    }

    private var isExpanded: Bool {
        isFocused || autofocus || hasAttachments || !text.isEmpty
    }

    /// Active slash token, if the caret sits right behind one: a `/` at the
    /// start or after whitespace, with no whitespace following it.
    private var slashQuery: String? {
        guard onSlashCommand != nil, !slashCommands.isEmpty,
              let last = text.last, !last.isWhitespace,
              let slashIndex = text.lastIndex(of: "/") else { return nil }
        if slashIndex != text.startIndex {
            guard text[text.index(before: slashIndex)].isWhitespace else { return nil }
        }
        let query = String(text[text.index(after: slashIndex)...])
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return query
    }

    private var slashSuggestions: [(id: String, gloss: String, icon: String)]? {
        guard let query = slashQuery else { return nil }
        let needle = query.lowercased()
        let matches = slashCommands.filter { needle.isEmpty || $0.id.lowercased().hasPrefix(needle) }
        return matches.isEmpty ? nil : Array(matches.prefix(6))
    }

    var body: some View {
        // The editor stays in the same hierarchy slot in both states.
        // It used to move between a VStack branch and an HStack branch when
        // `isFocused` flipped `isExpanded`, which destroyed the focused
        // TextField on every tap and looped focus loss -> collapse -> focus.
        VStack(alignment: .leading, spacing: 7) {
            if let suggestions = slashSuggestions {
                slashCard(suggestions)
            }
            HStack(spacing: 7) {
                if !isExpanded {
                    leading
                }
                editor
                    .lineLimit(isExpanded ? 4 : 1)
                if !isExpanded {
                    Spacer(minLength: 0)
                    if showsMicrophone { microphone }
                    submit
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The control row is the last row of the card, so it always sits
            // at the inner bottom edge no matter how tall the editor grows.
            if isExpanded {
                HStack(spacing: 7) {
                    leading
                    configuration
                    if showsMicrophone { microphone }
                    submit
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isExpanded ? 12 : 10)
        .padding(.top, isExpanded ? 10 : 8)
        // Match the top inset so the control row can breathe above the glass edge.
        .padding(.bottom, isExpanded ? 10 : 8)
        .frame(minHeight: isExpanded ? 100 : 52)
        .dshFloatingChrome(RoundedRectangle(cornerRadius: isExpanded ? 22 : 28, style: .continuous))
        .onAppear { if autofocus { isFocused = true } }
    }

    private var editor: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 17))
            .focused($isFocused)
            .onSubmit(onSubmit)
    }

    private var microphone: some View {
        Button { isFocused = true } label: {
            DSHRemoteMicrophoneGlyph()
                .frame(width: 34, height: 34)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("语音输入")
    }

    private func slashCard(_ suggestions: [(id: String, gloss: String, icon: String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(suggestions, id: \.id) { item in
                Button {
                    onSlashCommand?(item.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 30, height: 30)
                            .background(Color.accentColor.opacity(0.1), in: Circle())
                        Text("/\(item.id)")
                            .font(.system(size: 15).monospaced())
                            .foregroundStyle(Color.accentColor)
                        Text(item.gloss)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("/\(item.id) \(item.gloss)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Completes the trailing `/query` token with the chosen command, keeping
/// everything typed before it. Shared by both composers.
func dshCompleteSlashCommand(_ command: String, in text: String) -> String {
    guard let slashIndex = text.lastIndex(of: "/") else { return text }
    return String(text[..<slashIndex]) + "/\(command) "
}

/// A native anchored menu, deliberately not a sheet/card. These are the only
/// three controls hidden by the compact-editor preference. The two command
/// entries are real slash-command shortcuts; choosing one sends it through
/// the same command path as the expanded editor.
struct DSHComposerQuickActionsMenu: View {
    let onCommand: (String) -> Void
    let onPhoto: () -> Void
    let onFile: () -> Void
    var onCamera: (() -> Void)? = nil
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            DSHRemotePlusGlyph()
                .frame(width: 34, height: 34)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                menuSectionHeader("快捷指令")
                menuRow(title: "方案模式", subtitle: "/plan · 先规划再执行",
                        icon: .plan) { onCommand("plan") }
                menuRow(title: "追求目标", subtitle: "/goal · 设置长期目标",
                        icon: .goal) { onCommand("goal") }
                Divider()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                menuSectionHeader("添加附件")
                menuRow(title: "文件", subtitle: "从文件 App 选取",
                        icon: .file, action: onFile)
                if onCamera != nil && DSHCameraPicker.isAvailable {
                    menuRow(title: "相机", subtitle: "拍摄一张照片",
                            icon: .camera, action: { onCamera?() })
                }
                menuRow(title: "照片", subtitle: "从相簿选取",
                        icon: .photos, action: onPhoto)
            }
            .padding(.vertical, 8)
            .frame(width: 280)
            .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("More actions")
        .tint(.primary)
    }

    private func menuSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 4)
    }

    private func menuRow(title: String, subtitle: String, icon: DSHRemoteActionGlyph.Kind,
                         action: @escaping () -> Void) -> some View {
        Button {
            isPresented = false
            action()
        } label: {
            HStack(spacing: 12) {
                DSHRemoteActionGlyph(kind: icon)
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(subtitle)")
    }
}

/// System camera capture for composer attachments. The quick-actions menu
/// only offers the camera row when this reports available, so the entry
/// never degrades into a second photo picker.
struct DSHCameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: DSHCameraPicker

        init(parent: DSHCameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

/// Context usage ring: track plus an arc whose length follows the usage
/// ratio. One monochrome color like every other composer control; only the
/// arc length carries information. The exact percent lives in the
/// accessibility label and the popover.
/// Shared by the conversation and new-session composers.
struct DSHContextRing: View {
    let ratio: Double

    var body: some View {
        DSHRemoteContextGlyph(progress: ratio)
        .frame(width: 34, height: 34)
    }
}

/// Tracks the actual transcript viewport, including keyboard-driven resizing.
/// Layout changes preserve follow state; only a user scroll can disarm it.
@MainActor
final class DSHScrollCoordinator: NSObject {
    private(set) weak var scrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var pinScheduled = false
    private var isAnimatingJump = false
    private(set) var isFollowingLatest = true
    var followingChanged: ((Bool) -> Void)?

    func attach(_ view: UIScrollView) {
        guard scrollView !== view else { return }
        observations.removeAll()
        scrollView = view
        observations = [
            view.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.schedulePin() }
            },
            view.observe(\.adjustedContentInset, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.schedulePin() }
            },
            view.observe(\.contentInset, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.schedulePin() }
            },
            view.observe(\.frame, options: [.old, .new]) { [weak self] _, change in
                MainActor.assumeIsolated {
                    if change.oldValue?.size != change.newValue?.size { self?.schedulePin() }
                }
            },
            view.observe(\.bounds, options: [.old, .new]) { [weak self] view, change in
                MainActor.assumeIsolated {
                    if change.oldValue?.size != change.newValue?.size {
                        self?.schedulePin()
                    } else if view.isTracking || view.isDragging || view.isDecelerating {
                        self?.userDidScroll()
                    }
                }
            }
        ]
        schedulePin()
    }

    private var bottomOffset: CGFloat {
        guard let scrollView else { return 0 }
        return max(-scrollView.adjustedContentInset.top,
                   scrollView.contentSize.height - scrollView.bounds.height
                    + scrollView.adjustedContentInset.bottom)
    }

    func userDidScroll() {
        guard let scrollView else { return }
        setFollowing(bottomOffset - scrollView.contentOffset.y <= 24)
    }

    private func setFollowing(_ following: Bool) {
        guard following != isFollowingLatest else { return }
        isFollowingLatest = following
        // KVO can fire during layout; publish SwiftUI state on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.followingChanged?(self.isFollowingLatest)
        }
    }

    func resumeFollowing(animated: Bool = false) {
        setFollowing(true)
        guard animated, !UIAccessibility.isReduceMotionEnabled, let scrollView else {
            schedulePin()
            return
        }
        isAnimatingJump = true
        UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]) {
            scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x, y: self.bottomOffset)
        } completion: { [weak self] _ in
            guard let self else { return }
            self.isAnimatingJump = false
            self.schedulePin()
        }
    }

    func schedulePin() {
        guard isFollowingLatest, !pinScheduled, !isAnimatingJump else { return }
        pinScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pinScheduled = false
            guard self.isFollowingLatest, !self.isAnimatingJump else { return }
            self.scrollToBottom(animated: false)
        }
    }

    func scrollToBottom(animated: Bool) {
        guard let scrollView, !scrollView.isTracking, !scrollView.isDragging,
              !scrollView.isDecelerating else { return }
        let target = CGPoint(x: scrollView.contentOffset.x, y: bottomOffset)
        guard abs(scrollView.contentOffset.y - target.y) > 0.5 else { return }
        scrollView.setContentOffset(target, animated: animated)
    }
}

/// Probe view that reports the enclosing scroll view on mount. Mount-based
/// (not update-based): SwiftUI skips updateUIView when the representable's
/// inputs never change, so an update-only walk can stay nil forever when its
/// first call races attachment.
private final class DSHScrollProbeView: UIView {
    weak var coordinator: DSHScrollCoordinator?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        resolveScrollView()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        resolveScrollView()
    }

    private func resolveScrollView() {
        guard superview != nil else { return }
        var current = superview
        while let candidate = current {
            if let scrollView = candidate as? UIScrollView {
                coordinator?.attach(scrollView)
                return
            }
            current = candidate.superview
        }
    }
}

private struct DSHScrollFinder: UIViewRepresentable {
    let coordinator: DSHScrollCoordinator

    func makeUIView(context: Context) -> UIView {
        let view = DSHScrollProbeView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.coordinator = coordinator
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        var current = uiView.superview
        while let candidate = current {
            if let scrollView = candidate as? UIScrollView {
                coordinator.attach(scrollView)
                return
            }
            current = candidate.superview
        }
    }
}

/// All conversation modal presentations in one modifier. Extracted from
/// `ConversationView.body` so ten nested presentation modifiers don't share
/// its type-check budget. Pure plumbing: bindings flow straight through,
/// sheet content is shared, and `model` passes through for the sheets'
/// own `environmentObject` injection (they observe it themselves).
private struct ConversationModals: ViewModifier {
    @Binding var showCommandMenu: Bool
    @Binding var showModelPicker: Bool
    @Binding var showPermissionPicker: Bool
    @Binding var showFilesPanel: Bool
    @Binding var showUsagePanel: Bool
    @Binding var showQueuedList: Bool
    @Binding var showNewSession: Bool
    @Binding var showCamera: Bool
    @Binding var showDraftPreview: Bool
    @Binding var showPhotoPicker: Bool
    @Binding var selectedPhotos: [PhotosPickerItem]
    @Binding var capturedPhoto: UIImage?
    @Binding var draftAttachments: [DSHStagedAttachment]
    let draftPreviewImage: UIImage?
    let sessionID: String
    let workspaceID: String?
    let model: DSHAppModel
    let handleMenuCommand: (String) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showCommandMenu) {
                CommandMenuSheet(
                    onCommand: { command in
                        showCommandMenu = false
                        handleMenuCommand(command)
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
            .sheet(isPresented: $showFilesPanel) {
                RemoteFilesPanel(sessionID: sessionID)
                    .environmentObject(model)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
            }
            .sheet(isPresented: $showUsagePanel) {
                RemoteUsagePanel(sessionID: sessionID)
                    .environmentObject(model)
                    .presentationDetents([.medium, .large])
            }
            .photosPicker(isPresented: $showPhotoPicker,
                          selection: $selectedPhotos,
                          maxSelectionCount: 10,
                          matching: .images)
            .fullScreenCover(isPresented: $showDraftPreview) {
                if let draftPreviewImage {
                    DSHImageViewer(image: draftPreviewImage, name: "预览")
                }
            }
            .fullScreenCover(isPresented: $showNewSession) {
                NewSessionSheet(initialWorkspaceID: workspaceID)
                    .environmentObject(model)
            }
            .sheet(isPresented: $showQueuedList) {
                QueuedPromptsSheet(sessionID: sessionID)
                    .environmentObject(model)
                    .presentationDetents([.medium])
            }
            .fullScreenCover(isPresented: $showCamera) {
                DSHCameraPicker(image: $capturedPhoto)
                    .ignoresSafeArea()
            }
            .onChange(of: capturedPhoto) { _, photo in
                guard let photo else { return }
                capturedPhoto = nil
                // JPEG encoding a 12MP capture blocks briefly; keep it off
                // the main actor like the photo-library path.
                Task { @MainActor in
                    let raw = await Task.detached(priority: .userInitiated) {
                        photo.jpegData(compressionQuality: 0.9)
                    }.value
                    guard let raw else { return }
                    let optimized = await optimizedPhotoDataOffMain(raw)
                    draftAttachments.append(DSHStagedAttachment(name: "camera.jpg",
                                                                data: optimized,
                                                                isImage: true))
                }
            }
    }
}

/// All conversation follow-up observers in one modifier. Extracted from
/// `ConversationView.body` so nine nested `onChange` closures don't share
/// its type-check budget. Behavior is verbatim: every closure funnels
/// through the following guard (via `pinToBottom`), so a reader parked on
/// history is never yanked.
private struct ConversationObservers: ViewModifier {
    let messageCount: Int
    let sessionUpdatedAt: Int64??
    let entriesCount: Int
    let streamingSignature: String
    let isRunning: Bool
    let sessionID: String
    let initialVisibleLimit: Int
    @Binding var visibleSectionLimit: Int
    @Binding var selectedPhotos: [PhotosPickerItem]
    let model: DSHAppModel
    let pinToBottom: () -> Void
    let runningChanged: (Bool) -> Void
    let stagePhotos: ([PhotosPickerItem]) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: messageCount) { _, _ in
                model.markSessionRead(sessionID)
                pinToBottom()
            }
            .onChange(of: sessionUpdatedAt) { _, _ in
                model.markSessionRead(sessionID)
            }
            .onChange(of: entriesCount) { _, _ in
                pinToBottom()
            }
            .onChange(of: streamingSignature) { _, _ in
                // Assistant deltas mutate the current message instead of
                // appending a new one. This observer keeps a reader at the
                // bottom during a live answer while the pin still respects
                // the manual-scroll guard.
                pinToBottom()
            }
            .onChange(of: isRunning) { _, running in
                runningChanged(running)
            }
            .onChange(of: sessionID) {
                visibleSectionLimit = initialVisibleLimit
            }
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty else { return }
                selectedPhotos = []
                // Both the expanded photo button and compact plus menu use the
                // same staging path, so selection never uploads immediately.
                stagePhotos(items)
            }
    }
}

struct ConversationView: View {
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: String

    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var capturedPhoto: UIImage?
    @State private var draftPreviewImage: UIImage?
    @State private var showDraftPreview = false
    @State private var showCommandMenu = false
    @State private var showModelPicker = false
    @State private var showPermissionPicker = false
    @State private var showNewSession = false
    @State private var showQueuedList = false
    @State private var showFilesPanel = false
    @State private var showUsagePanel = false
    @State private var showContextPopover = false
    @State private var showRenameSession = false
    @State private var renameSessionText = ""
    /// UIKit fallback for viewport moves; never observed, only driven.
    @State private var scrollCoordinator = DSHScrollCoordinator()
    /// Render-window size (see windowedTranscriptSections). A fresh view per
    /// pushed session starts at the initial limit; the onChange below covers
    /// the reused-view edge.
    @State private var visibleSectionLimit = transcriptInitialLimit
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
    /// When this device first saw the current turn run. Drives the live
    /// elapsed clock above the composer; cleared when the turn settles.
    @State private var turnStartedAt: Date?
    private static let bottomAnchor = "conversation-bottom"

    private var session: DSHSessionSummary? { model.sessions.first { $0.id == sessionID } }
    private var isRunning: Bool { model.turnState(for: sessionID).lowercased() == "running" }
    /// Any tool literally running right now. The live trail keys off this —
    /// not the turn flag alone — so tools in flight always surface above the
    /// composer even when the turn state arrives late or goes stale.
    private var hasLiveToolActivity: Bool {
        model.tools(for: sessionID).contains { $0.status.lowercased() == "running" }
    }
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
        let machine = model.machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        let machineLabel = machine.isEmpty ? "Mac" : machine
        let mode = model.modeLabel(for: sessionID)
        if let workspace = session?.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines), !workspace.isEmpty {
            return "\(mode) · \(workspace) · \(machineLabel)"
        }
        if let cwd = session?.cwd, let last = cwd.split(separator: "/").last, !last.isEmpty {
            return "\(mode) · \(last) · \(machineLabel)"
        }
        return "\(mode) · DSH Anywhere · \(machineLabel)"
    }

    /// Sections actually rendered. While the turn runs, reasoning-only turns
    /// (think steps with no answer text yet) are withheld: all thinking
    /// progress lives in the live trail above the composer, so the transcript
    /// never sprouts "思考" rows mid-output. They reappear folded into the
    /// finished turn the moment it settles.
    private var visibleTranscriptSections: [DSHTranscriptSection] {
        let sections = model.transcriptSections(for: sessionID)
        guard isRunning else { return sections }
        return sections.filter {
            guard case .turn(let block, _) = $0 else { return true }
            return block.isUserTurn || !block.visibleMessages.isEmpty
        }
    }

    /// Render-window sizing: first paint shows the newest slice only.
    private static let transcriptInitialLimit = 50
    private static let transcriptPageSize = 100

    private var windowedTranscriptSections: [DSHTranscriptSection] {
        let sections = visibleTranscriptSections
        guard sections.count > visibleSectionLimit else { return sections }
        return Array(sections.suffix(visibleSectionLimit))
    }

    private var hiddenSectionCount: Int {
        max(0, visibleTranscriptSections.count - visibleSectionLimit)
    }

    /// One transcript section as a view. Lives outside `body` so the giant
    /// switch type-checks in its own budget unit instead of inside the view
    /// body's single expression.
    @ViewBuilder
    private func transcriptSectionView(_ section: DSHTranscriptSection) -> some View {
        switch section {
        case .turn(let block, let tools):
            if block.isUserTurn {
                MessageBubble(sessionID: sessionID, message: block.messages[0]).id(section.id)
            } else {
                AssistantTurnView(sessionID: sessionID,
                                  block: block,
                                  tools: tools,
                                  onBranch: createBranchSession).id(section.id)
            }
        case .row(let entry):
            switch entry {
            case .turn(let block):
                if block.isUserTurn {
                    MessageBubble(sessionID: sessionID, message: block.messages[0]).id(section.id)
                } else {
                    AssistantTurnView(sessionID: sessionID,
                                      block: block,
                                      tools: [],
                                      onBranch: createBranchSession).id(section.id)
                }
            case .tool(let tool):
                // A tool with no preceding assistant turn
                // (history edge): keep it visible standalone.
                ToolActivityCard(tool: tool).id(section.id)
            case .command(let result):
                CommandResultCard(result: result).id(section.id)
            case .modelChange(let notice):
                ModelChangeCard(notice: notice).id(section.id)
            }
        }
    }

    /// Pages the render window back by one page, keeping the old top row
    /// pinned under the header so the viewport does not jump. Called by the
    /// tap button and by the top sentinel (scroll-to-top auto-loads).
    private func loadEarlierSections(proxy: ScrollViewProxy) {
        guard hiddenSectionCount > 0 else { return }
        let anchorID = windowedTranscriptSections.first?.id
        visibleSectionLimit += Self.transcriptPageSize
        if let anchorID {
            DispatchQueue.main.async {
                proxy.scrollTo(anchorID, anchor: .top)
            }
        }
    }

    /// The "load earlier" banner above the windowed list. Extracted from
    /// `body` so its nested closures don't share the body's type-check
    /// budget. Empty when everything is already shown.
    @ViewBuilder
    private func loadEarlierBanner(proxy: ScrollViewProxy) -> some View {
        if hiddenSectionCount > 0 {
            // Scrolling to the very top pages automatically; appearing
            // without a disappear cycle does not refire, so this cannot loop.
            Color.clear
                .frame(height: 1)
                .onAppear { loadEarlierSections(proxy: proxy) }
            HStack {
                Spacer(minLength: 0)
                Button {
                    loadEarlierSections(proxy: proxy)
                } label: {
                    loadEarlierLabel
                }
                .accessibilityLabel("加载更早的对话内容")
                Spacer(minLength: 0)
            }
        }
    }

    private var loadEarlierLabel: some View {
        Text("↑ 加载更早 \(hiddenSectionCount) 段")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .padding(.vertical, 8)
    }

    /// Pending approval/question cards inline in the transcript. Extracted
    /// from `body` so their closures don't share its type-check budget.
    @ViewBuilder
    private func inlineDecisionCards() -> some View {
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
    }

    private func bottomAnchorView() -> some View {
        Color.clear.frame(height: 1).id(Self.bottomAnchor)
    }

    /// The transcript scroll view with its chrome. Extracted from `body` so
    /// the ScrollView/LazyVStack nesting type-checks in its own budget unit.
    @ViewBuilder
    private func transcriptScrollView(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                // Render window: only the newest sections mount,
                // so a long session never pays full-list diffing
                // on every token. Older rows stay in the local
                // store and page in on demand (no protocol round
                // trip); thinking still expands in place on tap.
                loadEarlierBanner(proxy: proxy)
                ForEach(windowedTranscriptSections) { section in
                    transcriptSectionView(section)
                }
                inlineDecisionCards()
                if !hasRenderedContent {
                    emptyConversationState
                }
                bottomAnchorView()
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(DSHScrollFinder(coordinator: scrollCoordinator))
        }
        // Let the transcript pass behind the floating material while the
        // real safe-area insets keep its resting first/last rows unobscured.
        .scrollClipDisabled()
        // No `.defaultScrollAnchor`: it fights the programmatic scrollTo
        // below (system anchor vs manual pinning cancel each other and the
        // jump button goes dead). Pinning is fully owned by scrollToLatest
        // on every content change instead.
        .background(Color(.systemBackground))
        .refreshable {
            // Remote's pull-to-refresh rehydrates both the task metadata
            // and the durable transcript without creating a second socket
            // or replaying the whole event stream.
            model.refreshSessions(includeArchived: true)
            model.sendModelCatalog()
            model.openSession(sessionID)
        }
        // Dragging the transcript puts the keyboard away with the finger
        // following it (`.interactively` is the only system-supported
        // finger-tracked dismissal). `.always` keeps the bounce gesture
        // available even when a short conversation has nothing to scroll,
        // which is what the removed keyboard "Done" bar was working
        // around. Back-swipe is the system's full-screen interactive pop
        // (see DSHInteractivePopGestureEnabler), not a custom gesture, so
        // it tracks force/velocity and can be cancelled mid-swipe.
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.always)
    }

    var body: some View {
        ScrollViewReader { proxy in
            transcriptScrollView(proxy: proxy)
                .safeAreaInset(edge: .top, spacing: 0) {
                    happyConversationHeader
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    composer(proxy: proxy)
                        .padding(.bottom, 8)
                }
            .background(Color(.systemBackground))
            .onAppear {
                scrollCoordinator.followingChanged = { following in
                    withAnimation(.easeInOut(duration: 0.25)) { isFollowingLatest = following }
                }
                scrollCoordinator.schedulePin()
            }
            .onDisappear { scrollCoordinator.followingChanged = nil }
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
            .modifier(ConversationObservers(messageCount: model.messages(for: sessionID).count,
                                            sessionUpdatedAt: session?.updatedAt,
                                            entriesCount: transcriptEntries.count,
                                            streamingSignature: latestStreamingSignature,
                                            isRunning: isRunning,
                                            sessionID: sessionID,
                                            initialVisibleLimit: Self.transcriptInitialLimit,
                                            visibleSectionLimit: $visibleSectionLimit,
                                            selectedPhotos: $selectedPhotos,
                                            model: model,
                                            pinToBottom: { self.scrollToLatest(proxy) },
                                            runningChanged: { self.handleRunningChange($0, proxy: proxy) },
                                            stagePhotos: { self.stageSelectedPhotos($0) }))
            .modifier(ConversationModals(showCommandMenu: $showCommandMenu,
                                             showModelPicker: $showModelPicker,
                                             showPermissionPicker: $showPermissionPicker,
                                             showFilesPanel: $showFilesPanel,
                                             showUsagePanel: $showUsagePanel,
                                             showQueuedList: $showQueuedList,
                                             showNewSession: $showNewSession,
                                             showCamera: $showCamera,
                                             showDraftPreview: $showDraftPreview,
                                             showPhotoPicker: $showPhotoPicker,
                                             selectedPhotos: $selectedPhotos,
                                             capturedPhoto: $capturedPhoto,
                                             draftAttachments: $draftAttachments,
                                             draftPreviewImage: draftPreviewImage,
                                             sessionID: sessionID,
                                             workspaceID: session?.workspaceId,
                                             model: model,
                                             handleMenuCommand: { self.handleMenuCommand($0) }))
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.data], allowsMultipleSelection: true,
                          onCompletion: handleFileImporterResult)
            .alert("重命名会话", isPresented: $showRenameSession) {
                TextField("会话名称", text: $renameSessionText)
                Button("取消", role: .cancel) { }
                Button("保存") { renameSession() }
            } message: {
                Text("名称会在 Mac 确认后同步到所有设备。")
            }
        }
    }

    /// Remote's task header is intentionally quiet: title and project/device
    /// subtitle are centered on the white surface, with a back button on the
    /// left and a compact edit/menu capsule on the right.
    private var happyConversationHeader: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                if #available(iOS 26, *) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: Circle())
                } else {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(Color(.systemBackground), in: Circle())
                        .overlay { Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.75) }
                        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            VStack(alignment: .leading, spacing: 1) {
                Text(conversationTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(conversationSubtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                Button { showNewSession = true } label: {
                    DSHRemoteComposeGlyph(size: 20)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新建会话")

                Menu {
                    Button {
                        UIPasteboard.general.string = sessionID
                    } label: {
                        Label("复制对话串 ID", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) { archiveSession() } label: {
                        Label("归档", systemImage: "archivebox")
                    }
                    Divider()
                    Button { beginRenameSession() } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Button { showFilesPanel = true } label: {
                        Label("文件", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("会话选项")
            }
            .frame(width: 88, height: 44)
            .dshFloatingChrome(Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        // The shared 50% page-color surface also covers the status area.
        .background(DSHHeaderBackdrop())
        .overlay(alignment: .bottom) {
            Color.primary.opacity(0.1).frame(height: 0.5)
        }
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
    private func composer(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Jump-to-latest lives at the very top of the dock, so its bottom
            // edge always clears the composer's top edge by the stack spacing
            // plus its own bottom padding. It used to float in an overlay
            // positioned from a measured composer height, which drifted and
            // let it cover the input card.
            // Only while the reader is away from the newest output: the whole
            // point is to not need this button when already at the bottom.
            if !isFollowingLatest {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { isFollowingLatest = true }
                        scrollCoordinator.resumeFollowing(animated: true)
                    } label: {
                        // Glass disc on iOS 26+ (transcript shows through it);
                        // below that, the ghost arrow: no disc background so
                        // the button never masks the transcript underneath.
                        if #available(iOS 26, *) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 48, height: 48)
                                .glassEffect(.regular, in: Circle())
                        } else {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                                .frame(width: 48, height: 40)
                                .opacity(0.5)
                        }
                    }
                    .accessibilityLabel("Jump to latest output")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .scale(scale: 0.8)).combined(with: .move(edge: .bottom)))
            }

            if !draftAttachments.isEmpty {
                draftAttachmentStrip
            }

            // Live turn status rides above the input card while work happens,
            // so a reader who scrolled away still sees that work is happening
            // (and what it is doing) instead of a frozen screen. Gated on
            // actual tool activity — not only the turn state — so a stale
            // turn flag can never hide a running 读取/编辑/Bash.
            if isRunning || hasLiveToolActivity {
                liveTurnStatus
            }

            // Queued prompts bubble: prompts this device queued behind the
            // run, newest last. One shows its text, several show the count;
            // tapping opens the detail list. Entries retire when accepted.
            if !model.queuedPrompts(for: sessionID).isEmpty {
                queuedPromptBubble
            }

            // Failed send: the prompt never got its acceptance. Says whether
            // it died locally or on the Mac side, and offers a retry with the
            // original text (and receipts) intact.
            if let failed = model.failedSend, failed.sessionID == sessionID {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(failedSendTitle(failed))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(failed.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Button("重试") { model.retryFailedSend() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Button {
                        model.dismissFailedSend()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("关闭发送失败提示")
                }
                .padding(10)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(failedSendTitle(failed))：\(failed.text)")
            }

            compactComposer

            if hasRenderedContent && model.showUsageFooter && hasSessionUsageData {
                Button { showUsagePanel = true } label: {
                    UsageFooter(usage: model.usage(for: sessionID))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看本会话统计")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 8)
    }

    private var hasSessionUsageData: Bool {
        guard let usage = model.usage(for: sessionID) else { return false }
        return usage.rounds != nil
            || usage.steps != nil
            || usage.inputTokens != nil
            || usage.outputTokens != nil
            || usage.totalTokens != nil
            || usage.cacheReadTokens != nil
            || usage.cacheWriteTokens != nil
            || usage.cacheHitPercent != nil
            || usage.tokensPerSecond != nil
            || usage.contextUsed != nil
            || usage.contextWindow != nil
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
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    draftPreviewImage = image
                                    showDraftPreview = true
                                }
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
        DSHRemoteComposer(text: $model.draft,
                          placeholder: composerPlaceholder,
                          hasAttachments: hasDraftAttachments,
                          autofocus: previewComposerFocused,
                          showsMicrophone: false,
                          onSubmit: { send() },
                          slashCommands: DSHSlashCommands,
                          onSlashCommand: { command in
                              model.draft = dshCompleteSlashCommand(command, in: model.draft)
                          }) {
            if model.collapseComposerControls {
                DSHComposerQuickActionsMenu(
                onCommand: { command in
                    if Self.commandNeedsArguments(command) { insertCommandAtHead(command) }
                    else { model.executeCommand("/\(command)", for: sessionID) }
                },
                onPhoto: { showPhotoPicker = true },
                onFile: { showFileImporter = true },
                    onCamera: { showCamera = true }
                )
            } else {
                HStack(spacing: 0) {
                    Button { showCommandMenu = true } label: {
                        Image(systemName: "slash.circle").frame(width: 34, height: 34)
                    }
                    .accessibilityLabel("Commands")
                    Button { showPhotoPicker = true } label: {
                        Image(systemName: "photo").frame(width: 34, height: 34)
                    }
                    .accessibilityLabel("Attach photos")
                    Button { showFileImporter = true } label: {
                        Image(systemName: "paperclip").frame(width: 34, height: 34)
                    }
                    .accessibilityLabel("Attach file")
                }
                .font(.system(size: DSHComposerGlyphHeight))
                .buttonStyle(.plain)
            }
        } configuration: {
            PermissionMenu(sessionID: sessionID, compact: true)
            Spacer(minLength: 0)
            contextUsageControl
            ReasoningEffortMenu(sessionID: sessionID, compact: true)
        } submit: {
            composerSendControl
        }
    }

    private var previewComposerFocused: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--dsh-preview-composer-focused")
        #else
        false
        #endif
    }


    private var composerPlaceholder: String {
        let machine = model.machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = machine.isEmpty ? "Mac" : machine
        return "在 \(name) 上工作"
    }

    /// Commands that are meaningless bare: sending "/plan" or "/goal" with no
    /// task text fires an empty command. They insert at the draft head for
    /// the user to complete instead. compact/export/feedback are valid bare
    /// and keep executing immediately; permission/model open their pickers.
    private static func commandNeedsArguments(_ command: String) -> Bool {
        command == "plan" || command == "goal"
    }

    /// Prepends "/command " at the draft head (replacing any leading token
    /// so re-tapping switches commands) and focuses the editor for arguments.
    private func insertCommandAtHead(_ command: String) {
        var text = model.draft
        if text.hasPrefix("/") {
            if let space = text.firstIndex(of: " ") {
                text = String(text[text.index(after: space)...])
            } else {
                text = ""
            }
        }
        model.draft = "/\(command) " + text
        isDraftFocused = true
    }

    /// Two live lines above the input card while the turn runs:
    /// "深度求索中… {elapsed}" ticking every second, plus the newest activity
    /// (running tool → streaming answer → thinking → waiting). The elapsed
    /// clock spans dispatch to completion: it starts at the newest accepted
    /// user message (the moment the Mac takes the task — uploads and local
    /// queue holds excluded), so the live count flows straight into the
    /// turn's final 用时 row. Falls back to first-running-seen, then now.
    @ViewBuilder
    private var liveTurnStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                Text("深度求索中… \(liveElapsedText(now: context.date))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Text(liveTrailText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 4)
        .onAppear {
            if turnStartedAt == nil { turnStartedAt = .now }
        }
    }

    private func liveElapsedText(now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(liveElapsedStart ?? now)))
        if total < 60 { return "\(total)秒" }
        if total < 3600 { return "\(total / 60)分\(total % 60)秒" }
        return "\(total / 3600)小时\((total % 3600) / 60)分"
    }

    /// Dispatch moment of the newest accepted user message (Mac clock), i.e.
    /// when the task actually started. Falls back to first-running-seen.
    private var liveElapsedStart: Date? {
        if let ms = model.messages(for: sessionID).last(where: { $0.role == .user })?.timestamp,
           ms > 0 {
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
        }
        return turnStartedAt
    }

    private func failedSendTitle(_ failed: DSHAppModel.DSHFailedSend) -> String {
        switch failed.failure {
        case .local:
            return "发送失败，本地连接不可用"
        case .server(let detail):
            return detail.isEmpty ? "发送失败，Mac 未响应" : "发送失败：\(detail)"
        }
    }

    /// Newest activity first: a running tool call beats streaming text, which
    /// beats a growing reasoning trace. The line carries live content (not
    /// just counts), so its motion itself proves the task is moving. Tool
    /// phrasing mirrors the web client ("读取 · path").
    private var liveTrailText: String {
        let tools = model.tools(for: sessionID)
        if let running = tools.last(where: { $0.status.lowercased() == "running" }) {
            return DSHToolPresentation.headline(for: running)
        }
        if let last = model.messages(for: sessionID).last, last.role == .assistant {
            if !last.markdown.isEmpty {
                let preview = Self.previewLine(last.markdown)
                return preview.isEmpty ? "正在输出…" : "正在输出 · \(preview)"
            }
            if let reasoning = last.reasoning, !reasoning.isEmpty {
                let preview = Self.previewLine(reasoning)
                return preview.isEmpty ? "思考中…" : "思考中 · \(preview)"
            }
        }
        return "等待响应…"
    }

    /// Newest non-empty line, flattened for the one-line trail. The tail —
    /// not the head — is what is being typed right now.
    private static func previewLine(_ text: String, limit: Int = 40) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return "" }
        return line.count > limit ? "…" + String(line.suffix(limit)) : String(line)
    }

    /// Queue bubble above the input card, pinned right. One queued prompt
    /// shows its text, several collapse to a count; tapping opens the detail
    /// list. Edit/cancel of server-side queued items needs a protocol
    /// addition (`session/updateQueue`); until then this mirrors what this
    /// device sent and retires entries on acceptance.
    @ViewBuilder
    private var queuedPromptBubble: some View {
        let queued = model.queuedPrompts(for: sessionID)
        if !queued.isEmpty {
            HStack {
                Spacer(minLength: 0)
                Button { showQueuedList = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 12, weight: .medium))
                        if queued.count == 1, let first = queued.first {
                            Text(first.text)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("\(queued.count)条排队")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    queued.count == 1 ? "排队中的消息" : "\(queued.count)条排队消息，查看详情")
            }
        }
    }

    @ViewBuilder
    private var contextUsageControl: some View {
        let ratio = contextRatio ?? 0
        Button { showContextPopover = true } label: {
            ContextRing(ratio: ratio)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("上下文窗口已使用 \(Int(ratio * 100))%")
        .popover(isPresented: $showContextPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text("上下文窗口")
                    .font(.headline)
                if let usage = model.usage(for: sessionID),
                   let used = usage.contextUsed,
                   let window = usage.contextWindow {
                    let remaining = max(0, window - used)
                    let percent = window > 0 ? Int((remaining / window) * 100) : 0
                    Text("剩余 \(percent)%（已用 \(chineseTokenCount(used)) / \(chineseTokenCount(window))）")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("暂无上下文用量数据")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func compactTokenCount(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return "\(Int(value))"
    }

    private func chineseTokenCount(_ value: Double) -> String {
        if value >= 10_000 {
            let amount = value / 10_000
            return amount.rounded() == amount ? "\(Int(amount))万" : String(format: "%.1f万", amount)
        }
        return "\(Int(value))"
    }

    @ViewBuilder private var composerSendControl: some View {
        if isSending {
            ProgressView()
                .tint(.white)
                .frame(width: 34, height: 34)
                .background(Color.accentColor, in: Circle())
                .accessibilityLabel("Sending")
        } else if isRunning, composerCanSend {
            // Staged text while a turn runs: sending never pauses the run.
            // The prompt joins behind it (queue) or redirects it (steer).
            Menu {
                Button("排队发送") { send(mode: "queue") }
                Button("插话发送") { send(mode: "steer") }
            } label: {
                sendCircle(enabled: true)
            }
            .accessibilityLabel("发送：排队或插话")
        } else if isRunning {
            Button(action: { model.cancelTurn(for: sessionID) }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Stop turn")
        } else {
            Button(action: { send() }) {
                sendCircle(enabled: composerCanSend)
            }
            .disabled(!composerCanSend)
            .accessibilityLabel("Send message")
        }
    }

    private func sendCircle(enabled: Bool) -> some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 34, height: 34)
            .background(enabled ? Color.accentColor : Color(.systemGray5), in: Circle())
            .foregroundStyle(enabled ? .white : .white.opacity(0.85))
    }

    private var composerCanSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasDraftAttachments
    }

    /// Context window usage, shown as a ring beside the model.
    private var contextRatio: Double? {
        guard let usage = model.usage(for: sessionID),
              let used = usage.contextUsed, let window = usage.contextWindow, window > 0 else { return nil }
        return min(1, max(0, used / window))
    }

    /// Keeps the newest output on screen, unless the reader has scrolled away.
    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool = false) {
        guard scrollCoordinator.isFollowingLatest else { return }
        if let scroll = scrollCoordinator.scrollView,
           scroll.isTracking || scroll.isDragging || scroll.isDecelerating { return }
        // Streaming deltas are intentionally not animated. The old
        // `withAnimation` ran once per token and kept Core Animation busy even
        // when the reader was already at the bottom, which made the phone warm
        // and caused visible stutter. The explicit jump button below still uses
        // an animation when the user asks for one.
        if animated {
            withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
        // Belt and suspenders: drive the real scroll view too. If SwiftUI's
        // scrollTo silently no-ops, the content offset still lands at the
        // same place. Same destination, so the two never fight.
        scrollCoordinator.scrollToBottom(animated: animated)
        scrollCoordinator.schedulePin()
    }

    /// Turn-state flips drive the live clock and re-anchor the transcript.
    /// Extracted from `body` so the repin closures don't share its
    /// type-check budget.
    private func handleRunningChange(_ running: Bool, proxy: ScrollViewProxy) {
        if running {
            if turnStartedAt == nil { turnStartedAt = .now }
        } else {
            turnStartedAt = nil
        }
        scrollToLatest(proxy)
    }

    /// Sends the draft without pausing the run: `queue` appends behind the
    /// current turn, `steer` redirects it (web parity). Queue-mode sends
    /// while busy are mirrored into the queue bubble until accepted.
    private func send(mode: String = "queue") {
        guard !isSending else { return }
        let text = model.draft
        let staged = draftAttachments
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !staged.isEmpty else { return }
        let wasRunning = isRunning
        // Text-only queue while busy stays on the device (editable,
        // cancellable, auto-fired when the turn settles). Anything with
        // attachments — and every steer — goes to the server immediately.
        if wasRunning && mode == "queue" && staged.isEmpty {
            model.holdQueuedPrompt(text: trimmed, for: sessionID)
            isDraftFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
            model.draft = ""
            return
        }
        if wasRunning && mode == "queue" {
            model.noteQueuedPrompt(text: trimmed, mode: mode, for: sessionID)
        }

        // Clear the editor immediately so a double tap cannot send the same
        // draft twice. If an upload fails, restore the not-yet-uploaded chips
        // below so the user can retry without selecting the files again.
        // The keyboard goes away with the send so the fresh answer is
        // visible. Both paths are needed: the expanded editor binds the
        // parent focus state, while the compact editor owns its focus
        // inside DSHRemoteComposer.
        isDraftFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
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
                                 messageAttachments: messageAttachments, to: sessionID,
                                 mode: mode)
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

    /// File-importer result handler, extracted as a named function so the
    /// view body's type-check budget stays bounded (a trailing closure here
    /// pushed the solver over its limit).
    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let accessed: Bool = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data: Data = try? Data(contentsOf: url) else { continue }
            let attachment = DSHStagedAttachment(name: url.lastPathComponent,
                                                 data: data,
                                                 isImage: url.isImageFile)
            draftAttachments.append(attachment)
        }
    }

    private func handleMenuCommand(_ command: String) {
        if command == "permission" { showPermissionPicker = true }
        else if command == "model" { showModelPicker = true }
        else if Self.commandNeedsArguments(command) { insertCommandAtHead(command) }
        else { model.executeCommand("/\(command)", for: sessionID) }
    }

    /// Stages picked photos without uploading. Extracted from `body` so the
    /// staging Task doesn't share its type-check budget.
    private func stageSelectedPhotos(_ items: [PhotosPickerItem]) {
        Task { @MainActor in
            var staged = 0
            for item in items.prefix(10) {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    // JPEG/downsampling is CPU work. Keep it off the main
                    // actor so choosing large iCloud photos does not make
                    // the composer freeze before the user can press Send.
                    let optimized = await optimizedPhotoDataOffMain(data)
                    let attachment = DSHStagedAttachment(name: "photo.jpg",
                                                         data: optimized,
                                                         isImage: true)
                    draftAttachments.append(attachment)
                    staged += 1
                } catch {
                    // One bad asset must not sink the other nine.
                    continue
                }
            }
            // `try?` used to swallow this, so a failure looked like
            // the button doing nothing at all.
            if staged == 0 { reportPhotoFailure() }
        }
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

    /// Starts a sibling task with the same machine/workspace/branch/model
    /// context. The Harness exposes no fork API, so the prior dialogue
    /// travels as the new session's first prompt (best effort, text only);
    /// the parent transcript remains untouched.
    private func createBranchSession() {
        guard let session else { return }
        let workspace: DSHWorkspaceOption?
        if let workspaceID = session.workspaceId {
            workspace = DSHWorkspaceOption(
                id: workspaceID,
                name: model.workspaceDisplayName(for: workspaceID,
                                                  fallback: session.workspaceName ?? ""))
        } else {
            workspace = nil
        }
        let selectedModel: DSHModelSelection?
        if let modelID = session.model, !modelID.isEmpty {
            selectedModel = DSHModelSelection(provider: session.provider ?? "deepseek",
                                               model: modelID,
                                               reasoningEffort: session.reasoningEffort)
        } else {
            selectedModel = nil
        }
        let parentTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        model.createSession(in: workspace,
                            title: parentTitle.isEmpty ? "新会话" : "\(parentTitle) 分支",
                            workingDirectory: session.cwd,
                            branch: session.branch,
                            mode: session.mode ?? session.agentPreset ?? "standard",
                            model: selectedModel,
                            permissionMode: session.permissionMode ?? "workspace-write",
                            initialPrompt: branchTranscriptText())
    }

    private func archiveSession() {
        model.archive(session ?? emptySession, archived: true)
        dismiss()
    }

    private func beginRenameSession() {
        renameSessionText = conversationTitle
        showRenameSession = true
    }

    private func renameSession() {
        let title = renameSessionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let session else { return }
        model.renameSession(session, to: title)
    }

    /// Prior dialogue carried into a branch as plain text (newest 40
    /// messages, hard-capped). Reasoning and tool detail stay behind;
    /// the new session continues from the readable Q&A.
    private func branchTranscriptText() -> String? {
        let messages = transcriptEntries.flatMap { entry -> [DSHChatMessage] in
            guard case .turn(let block) = entry else { return [] }
            return block.messages
        }
        .filter { !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .suffix(40)
        guard !messages.isEmpty else { return nil }
        var text = "以下是之前会话中的对话记录，请基于这些上下文继续协助我：\n\n" + messages.map { message in
            let body = message.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.role == .user ? "用户：\(body)" : "助手：\(body)"
        }.joined(separator: "\n\n")
        if text.count > 12_000 {
            text = "…（更早记录已省略）\n\n" + String(text.suffix(12_000))
        }
        return text
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
        private var fullscreenPop: UIPanGestureRecognizer?

        func attach(to navigationController: UINavigationController) {
            guard self.navigationController !== navigationController else {
                navigationController.interactivePopGestureRecognizer?.isEnabled = true
                Self.enableContentPopIfAvailable(on: navigationController)
                installFullscreenPopIfNeeded(on: navigationController)
                return
            }
            restore()
            self.navigationController = navigationController
            let gesture = navigationController.interactivePopGestureRecognizer
            previousDelegate = gesture?.delegate
            gesture?.delegate = self
            gesture?.isEnabled = true
            Self.enableContentPopIfAvailable(on: navigationController)
            installFullscreenPopIfNeeded(on: navigationController)
        }

        /// The system full-screen (anywhere-origin) interactive pop gesture.
        /// It tracks the finger with velocity and cancellation like the edge
        /// gesture, which the old decide-on-release custom DragGesture never
        /// could.
        /// Resolved at runtime (not `if #available`) so the iOS 17 deployment
        /// target keeps working: where the API is absent this is a no-op and
        /// the edge gesture above remains the way back.
        private static func enableContentPopIfAvailable(on navigationController: UINavigationController) {
            // Built at runtime (not as a literal): Swift 6 validates
            // `Selector("…")` literals at compile time, and this API is newer
            // than the iOS 17 deployment target, so a literal is a build
            // error even though the responds(to:) guard would be safe.
            let key = "interactiveContentPop" + "GestureRecognizer"
            guard navigationController.responds(to: NSSelectorFromString(key)),
                  let gesture = navigationController.value(forKey: key)
                    as? UIGestureRecognizer else { return }
            gesture.isEnabled = true
        }

        /// Full-screen fallback for the native content pop above. The native
        /// gesture stays disabled in our configuration (custom header, hidden
        /// navigation bar), so this reuses the edge gesture's own interactive
        /// transition driver for a pan that may start anywhere: same
        /// finger-tracking, velocity and cancellation as the system gesture.
        /// Private targets/action, resolved at runtime like above; the
        /// long-standing fullscreen-pop technique, kept as a fallback behind
        /// the native API.
        private func installFullscreenPopIfNeeded(on navigationController: UINavigationController) {
            if fullscreenPop != nil { return }
            guard let edge = navigationController.interactivePopGestureRecognizer,
                  let targets = edge.value(forKey: "targets") as? [NSObject],
                  let target = targets.first?.value(forKey: "target") as? NSObject else { return }
            let action = NSSelectorFromString("handleNavigationTransition:")
            guard target.responds(to: action) else { return }
            let pan = UIPanGestureRecognizer(target: target, action: action)
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            navigationController.view.addGestureRecognizer(pan)
            fullscreenPop = pan
        }

        func restore() {
            guard let navigationController,
                  let gesture = navigationController.interactivePopGestureRecognizer,
                  gesture.delegate === self else { return }
            gesture.delegate = previousDelegate
            gesture.isEnabled = true
            if let pan = fullscreenPop {
                navigationController.view.removeGestureRecognizer(pan)
                fullscreenPop = nil
            }
            self.navigationController = nil
            previousDelegate = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigationController,
                  navigationController.viewControllers.count > 1,
                  navigationController.presentedViewController == nil,
                  navigationController.transitionCoordinator == nil else { return false }
            // The fullscreen pan has no screen edge to anchor it: only begin
            // on a clearly rightward velocity, so vertical scrolls (and
            // leftward code-block pans) never become a back navigation.
            if gestureRecognizer === fullscreenPop,
               let pan = gestureRecognizer as? UIPanGestureRecognizer,
               let view = gestureRecognizer.view {
                let velocity = pan.velocity(in: view)
                return velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
            }
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
        DSHContextRing(ratio: ratio)
        .accessibilityLabel("Context \(Int(ratio * 100)) percent used")
    }
}


/// Adapts a live conversation to the same model picker used by a new draft.
private struct ReasoningEffortMenu: View {
    @EnvironmentObject private var model: DSHAppModel
    let sessionID: String
    var compact = false

    private var selection: DSHModelSelection {
        if let configuration = model.reasoningConfiguration(for: sessionID) {
            return DSHModelSelection(provider: configuration.provider, model: configuration.model,
                                     reasoningEffort: configuration.selectedEffortID)
        }
        let session = model.sessions.first { $0.id == sessionID }
        return DSHModelSelection(provider: session?.provider ?? model.modelCatalog?.default.provider ?? "",
                                 model: session?.model ?? model.modelCatalog?.default.model ?? "",
                                 reasoningEffort: session?.reasoningEffort)
    }

    var body: some View {
        DSHModelConfigurationPicker(
            catalog: model.modelCatalog,
            selection: Binding(get: { selection }, set: { _ in }),
            fallbackName: model.shortModelName(for: sessionID),
            fallbackEfforts: model.reasoningConfiguration(for: sessionID)?.efforts ?? [],
            compact: compact,
            onCommit: { model.selectModel($0, for: sessionID) }
        )
    }
}

private struct PermissionMenu: View {
    @EnvironmentObject private var model: DSHAppModel
    let sessionID: String
    var compact = false

    var body: some View {
        DSHComposerPermissionPicker(mode: Binding(
            get: { model.permissionMode(for: sessionID) },
            set: { model.setPermission($0, for: sessionID) }
        ), compact: compact)
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

private struct RemoteFilesPanel: View {
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: String

    private var attachments: [DSHUploadedAttachment] {
        model.attachments(for: sessionID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("会话文件")
                        .font(.system(size: 17, weight: .semibold))
                    Text(attachments.isEmpty ? "还没有上传文件" : "共 \(attachments.count) 个")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(.thinMaterial, in: Circle())
                        .overlay { Circle().stroke(Color.primary.opacity(0.10), lineWidth: 0.75) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                if attachments.isEmpty {
                    ContentUnavailableView("暂无文件", systemImage: "doc.on.doc",
                                           description: Text("用输入框的加号上传文件后，会显示在这里。"))
                        .padding(.top, 80)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(attachments) { file in
                            HStack(spacing: 12) {
                                Image(systemName: file.mediaType?.hasPrefix("image/") == true ? "photo" : "doc")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, height: 36)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(fileSubtitle(file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(Color(.systemBackground))
    }

    private func fileSubtitle(_ file: DSHUploadedAttachment) -> String {
        var parts: [String] = []
        if let mediaType = file.mediaType, !mediaType.isEmpty { parts.append(mediaType) }
        if let size = file.size, size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        return parts.isEmpty ? "已上传" : parts.joined(separator: " · ")
    }
}

/// Full session usage is kept behind the compact footer so the composer never
/// loses width. Tapping the footer opens the same native sheet treatment as
/// the Files pill and makes it clear these numbers cover the whole
/// conversation, not just the most recent turn.
private struct RemoteUsagePanel: View {
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: String

    private var usage: DSHSessionUsage? { model.usage(for: sessionID) }

    var body: some View {
        NavigationStack {
            List {
                Section("本会话") {
                    metric("轮次", usage?.rounds.map(String.init) ?? "—")
                    metric("步骤", usage?.steps.map(String.init) ?? "—")
                    metric("输入 Token", compact(usage?.inputTokens))
                    metric("输出 Token", compact(usage?.outputTokens))
                    metric("总 Token", compact(usage?.totalTokens))
                }
                Section("缓存与上下文") {
                    metric("缓存命中", usage?.cacheHitPercent.map { String(format: "%.2f%%", $0) } ?? "—")
                    metric("读取缓存", compact(usage?.cacheReadTokens))
                    metric("写入缓存", compact(usage?.cacheWriteTokens))
                    metric("平均速度", usage?.tokensPerSecond.map { String(format: "%.0f tok/s", $0) } ?? "—")
                    if let used = usage?.contextUsed, let window = usage?.contextWindow, window > 0 {
                        metric("上下文窗口", "剩余 " + compact(window - used) + " / " + compact(window))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("会话统计")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func compact(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return "\(Int(value))"
    }
}

/// Slash commands shared by the command sheet and the composer `/`
/// autocomplete. Attachments deliberately live outside this list: they have
/// their own photo/file buttons and must not resurface here.
let DSHSlashCommands: [(id: String, gloss: String, icon: String)] = [
    ("compact", "压缩以上对话内容", "rectangle.compress.vertical"),
    ("export", "将当前会话导出为 ZIP", "square.and.arrow.up"),
    ("feedback", "发送关于当前会话的反馈", "bubble.left.and.exclamationmark.bubble.right"),
    ("goal", "设置或查看长期任务目标", "target"),
    ("permission", "切换权限预设（沙箱模式与审批策略）", "checkmark.shield"),
    ("plan", "进入或退出计划模式", "list.clipboard"),
    ("model", "选择本会话使用的模型", "cpu"),
]

struct CommandMenuSheet: View {
    let onCommand: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Commands") {
                    ForEach(DSHSlashCommands, id: \.id) { item in
                        Button { onCommand(item.id) } label: {
                            Label {
                                // Show the literal command the row runs, so the sheet
                                // teaches the slash syntax instead of only describing it:
                                // icon, "/command", a space, then the Chinese gloss.
                                HStack(spacing: 0) {
                                    Text("/\(item.id)")
                                        .font(.body.monospaced())
                                        .foregroundStyle(.tint)
                                    Text(" \(item.gloss)")
                                        .foregroundStyle(.primary)
                                }
                            } icon: {
                                Image(systemName: item.icon).foregroundStyle(.tint)
                            }
                        }
                        .accessibilityLabel("/\(item.id) \(item.gloss)")
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
                                    let selection = DSHModelSelection(provider: group.id, model: item.id,
                                                                      reasoningEffort: item.reasoning?.defaultEffort)
                                    dismiss()
                                    // Same dismiss-first sequencing as the
                                    // effort popover: the refresh behind the
                                    // send stutters the sheet animation.
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        model.selectModel(selection, for: sessionID)
                                    }
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
                    // Providers the Harness failed to load used to vanish
                    // silently, leaving the user wondering where their models
                    // went. List them with the reported reason instead.
                    if !catalog.failures.isEmpty {
                        Section("不可用") {
                            ForEach(catalog.failures) { failure in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(failure.name).foregroundStyle(.secondary)
                                    Text(failure.message)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(failure.name)不可用：\(failure.message)")
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

private struct QueuedPromptsSheet: View {
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    @State private var editingItem: DSHAppModel.DSHQueuedPrompt?
    @State private var editingText = ""

    var body: some View {
        NavigationStack {
            List {
                let queued = model.queuedPrompts(for: sessionID)
                if queued.isEmpty {
                    Text("暂无排队消息")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(queued) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(item.mode == "steer" ? "插话" : "排队")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                if item.sent {
                                    Text("已发送·等待执行")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Text(item.sentAt, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(item.text)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !item.sent {
                                Button("立即发送") {
                                    sendNow(item)
                                }
                                .tint(.accentColor)
                                Button("编辑") {
                                    editingItem = item
                                    editingText = item.text
                                }
                                Button("取消", role: .destructive) {
                                    model.cancelQueuedPrompt(id: item.id, sessionID: sessionID)
                                }
                            }
                        }
                    }
                    Section {
                        Text("本机暂存的排队上轮结束自动发出，可编辑/取消/立即发送；已发送的由服务端执行，不可改删，接收后自动消失。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("排队消息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("编辑排队消息", isPresented: Binding(
                get: { editingItem != nil },
                set: { if !$0 { editingItem = nil } }
            )) {
                TextField("消息内容", text: $editingText, axis: .vertical)
                Button("取消", role: .cancel) { editingItem = nil }
                Button("保存") {
                    if let item = editingItem {
                        model.updateQueuedPrompt(id: item.id, text: editingText, sessionID: sessionID)
                    }
                    editingItem = nil
                }
            }
        }
    }

    private func sendNow(_ item: DSHAppModel.DSHQueuedPrompt) {
        guard model.takeQueuedPrompt(id: item.id, sessionID: sessionID) != nil else { return }
        model.sendPrompt(item.text, to: sessionID)
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

private struct MessageInteractionModifier: ViewModifier {
    let isUser: Bool
    let onCopy: () -> Void
    let onTapAssistant: () -> Void

    func body(content: Content) -> some View {
        if isUser {
            content.contextMenu {
                Button(action: onCopy) {
                    Label("复制", systemImage: "doc.on.doc")
                }
            }
        } else {
            content.onTapGesture(perform: onTapAssistant)
        }
    }
}

private struct MessageBubble: View {
    @EnvironmentObject private var model: DSHAppModel
    let sessionID: String
    let message: DSHChatMessage
    let onBranch: (() -> Void)?
    @State private var showActions = false
    @State private var didCopy = false

    init(sessionID: String, message: DSHChatMessage, onBranch: (() -> Void)? = nil) {
        self.sessionID = sessionID
        self.message = message
        self.onBranch = onBranch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Media lives outside the tinted bubble so photos are never
            // squeezed into (or masked by) its rounded shape.
            if !message.attachments.isEmpty {
                HStack {
                    if message.role == .user { Spacer(minLength: 36) }
                    MessageAttachmentsView(attachments: message.attachments,
                                           alignTrailing: message.role == .user)
                    if message.role != .user { Spacer(minLength: 0) }
                }
            }
            if !message.markdown.isEmpty {
                HStack {
                    if message.role == .user { Spacer(minLength: 36) }
                    if message.role == .user {
                        MarkdownBlockText(text: message.markdown)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .contentShape(Rectangle())
                            .modifier(MessageInteractionModifier(isUser: true,
                                                                 onCopy: copyMessage,
                                                                 onTapAssistant: {}))
                    } else {
                        // No bubble and deliberately no clip: the old rounded
                        // clip cut the square corners of code/table
                        // backgrounds, which read as an oval mask over the
                        // reply.
                        MarkdownBlockText(text: message.markdown)
                            .textSelection(.enabled)
                            .contentShape(Rectangle())
                            .modifier(MessageInteractionModifier(isUser: false,
                                                                 onCopy: copyMessage,
                                                                 onTapAssistant: {
                                                                     withAnimation(.easeOut(duration: 0.15)) {
                                                                         showActions = true
                                                                     }
                                                                 }))
                    }
                    if message.role != .user { Spacer(minLength: 0) }
                }
            }

            if message.role != .user && (model.showMessageActionsByDefault || showActions) {
                // The two glyphs share one visual height (resizable + fixed
                // height) so their top/bottom edges line up. Two SF Symbols
                // at the same font size never match visually because each
                // glyph carries its own bounding box — that was the mismatch
                // in the screenshot.
                HStack(spacing: 12) {
                    Button(action: copyMessage) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .resizable()
                            .scaledToFit()
                            .fontWeight(.medium)
                            .frame(height: 17)
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel(didCopy ? "Copied" : "Copy")

                    if let onBranch {
                        // One size down from copy, same centered box: quieter
                        // secondary action, still easy to hit.
                        Button(action: onBranch) {
                            Image(systemName: "arrow.triangle.branch")
                                .resizable()
                                .scaledToFit()
                                .fontWeight(.medium)
                                .frame(height: 14)
                                .frame(width: 28, height: 28)
                        }
                        .accessibilityLabel("从此分支新建会话")
                    }
                    if let timeText = messageTimeText {
                        Text(timeText)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Reply timestamp ("Tuesday 17:56" / "星期二 17:56"), stamped from the
    /// event envelope on first sighting. Absent for rows that predate it.
    private var messageTimeText: String? {
        guard let ms = message.timestamp, ms > 0 else { return nil }
        return Self.timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1_000))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "EEEE HH:mm"
        return formatter
    }()

    private func copyMessage() {        let attachmentLines = message.attachments.map { "📎 \($0.name)" }
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

}

/// Square thumbnails in one row so any number of quoted images stays tidy.
private struct MessageAttachmentsView: View {
    let attachments: [DSHMessageAttachment]
    /// User uploads sit on the right with the user's bubble; Mac-side
    /// attachments stay left with the assistant.
    var alignTrailing = false

    private var images: [DSHMessageAttachment] { attachments.filter(\.isImage) }
    private var files: [DSHMessageAttachment] { attachments.filter { !$0.isImage } }

    var body: some View {
        VStack(alignment: alignTrailing ? .trailing : .leading, spacing: 6) {
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(images) { attachment in
                            MessageAttachmentPreview(attachment: attachment)
                        }
                    }
                    // Short rows hug the leading edge of a horizontal
                    // scroller; stretch to the viewport so trailing
                    // alignment (user uploads) actually holds.
                    .frame(maxWidth: .infinity, alignment: alignTrailing ? .trailing : .leading)
                }
            }
            ForEach(files) { attachment in
                MessageAttachmentPreview(attachment: attachment)
            }
        }
        .frame(maxWidth: 300, alignment: alignTrailing ? .trailing : .leading)
    }
}

private struct MessageAttachmentPreview: View {
    @EnvironmentObject private var model: DSHAppModel
    let attachment: DSHMessageAttachment
    @State private var data: Data?

    var body: some View {
        Group {
            if let data, attachment.isImage, UIImage(data: data) != nil {
                MessageImageThumbnail(data: data, name: attachment.name)
            } else if !attachment.isImage {
                HStack(spacing: 8) {
                    Image(systemName: "paperclip")
                        .font(.caption.weight(.semibold))
                    Text(attachment.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                // Image bytes not in cache yet: keep the square slot so the
                // row does not jump when the thumbnail lands.
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 96, height: 96)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(attachment.name)
            }
        }
        .task(id: attachment.id) {
            // Receipt cache first (phone uploads); embedded thumbnail second
            // (web uploads, Mac-side and model-returned images).
            data = model.attachmentData(for: attachment) ?? attachment.thumbnailData
        }
    }
}

/// Full-screen image preview for staged and quoted thumbnails.
struct DSHImageViewer: View {
    let image: UIImage
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset = CGSize.zero

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(0.6, abs(dragOffset.height) / 600))
                .ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: max(0, dragOffset.height))
                .gesture(
                    DragGesture()
                        .onChanged { dragOffset = $0.translation }
                        .onEnded { value in
                            if value.translation.height > 120 {
                                dismiss()
                            } else {
                                withAnimation(.spring()) { dragOffset = .zero }
                            }
                        }
                )
            VStack {
                HStack {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭预览")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer(minLength: 0)
            }
        }
    }
}

/// Fixed square thumbnail: every quoted image occupies the same slot.
/// Tapping opens the full-screen viewer.
private struct MessageImageThumbnail: View {
    let data: Data
    let name: String

    @State private var showViewer = false

    var body: some View {
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { showViewer = true }
                .accessibilityLabel(name)
                .accessibilityAddTraits(.isButton)
                .fullScreenCover(isPresented: $showViewer) {
                    DSHImageViewer(image: image, name: name)
                }
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
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            if copied { Text(DSHLocalization.string("Copied")) }
                        }
                        .font(.caption2)
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
            .background(Color(.systemGray6), in: .rect(cornerRadius: 10))
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
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

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
    let sessionID: String
    let block: DSHTranscriptBlock
    let tools: [DSHToolActivity]
    let onBranch: () -> Void

    @State private var isExpanded = false
    /// Whether the open state came from the reader's own tap. Auto-opened
    /// traces collapse again when their tools settle, so finished steps never
    /// bury the conversation; a manually opened trace stays as left.
    @State private var manualExpansion = false

    private var text: String { block.reasoning }
    private var answerCount: Int { block.visibleMessages.count }
    private var usage: DSHSessionUsage? { block.visibleMessages.last?.usage }

    /// Live means literally running: failed/error/cancelled tools are
    /// settled, not live. Counting them as live kept turns (and the live
    /// trail) stuck open forever after any failure.
    private var hasRunningTools: Bool {
        tools.contains { $0.status.lowercased() == "running" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpandable || turnDurationText(usage) != nil {
                timelineRow
                // Same width as the reply text: no full-bleed. The old
                // -16 bleed drew the rule past the text on both sides.
                Divider()
                    .padding(.top, 8)
            }
            ForEach(block.visibleMessages) { message in
                MessageBubble(sessionID: sessionID, message: message, onBranch: onBranch)
                    .padding(.top, 12)
            }
        }
        .onAppear {
            if hasRunningTools { isExpanded = true }
        }
        .onChange(of: hasRunningTools) { _, running in
            // Never hide live work: a newly started tool reopens the trace.
            // When the tools settle, an auto-opened trace folds itself away;
            // one the reader opened by hand stays as left.
            if running {
                withAnimation(.easeOut(duration: 0.2)) { isExpanded = true; manualExpansion = false }
            } else if !manualExpansion {
                withAnimation(.easeOut(duration: 0.2)) { isExpanded = false }
            }
        }
    }

    private var isExpandable: Bool {
        !block.reasoning.isEmpty || !tools.isEmpty
    }

    /// Reference layout: timing text with the chevron tucked right behind
    /// it (not pinned to the trailing edge), then a full-bleed divider.
    @ViewBuilder
    private var timelineRow: some View {
        if isExpandable {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle(); manualExpansion = true }
            } label: {
                timelineLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            .accessibilityLabel(DSHLocalization.string(isExpanded ? "Hide reasoning" : "Show reasoning"))
            .accessibilityHint(answerCount > 1
                ? String(format: DSHLocalization.string("Reasoning behind %lld answers in this turn"),
                         answerCount)
                : DSHLocalization.string("Reasoning behind this answer"))
        } else {
            timelineLabel
                .padding(.vertical, 8)
        }

        if isExpanded {
            VStack(alignment: .leading, spacing: 8) {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                }
                ForEach(tools) { tool in
                    ToolActivityCard(tool: tool)
                }
            }
            .padding(.bottom, 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var timelineLabel: some View {
        HStack(spacing: 6) {
            Text(timelineTitle)
                .font(.body)
                .foregroundStyle(.secondary)
            if isExpandable {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
    }

    private var timelineTitle: String {
        turnDurationText(usage) ?? DSHLocalization.string("Thinking")
    }

    /// Wall-clock estimate from the turn's own counters: tokens ÷ speed.
    private func turnDurationText(_ usage: DSHSessionUsage?) -> String? {
        guard let usage,
              let speed = usage.tokensPerSecond, speed > 0 else { return nil }
        let total = (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0)
        guard total > 0 else { return nil }
        let seconds = Int((total / speed).rounded())
        if seconds < 60 {
            return String(format: DSHLocalization.string("Took %lld sec"), seconds)
        }
        let minutes = seconds / 60
        let rest = seconds % 60
        if minutes < 60 {
            return rest == 0
                ? String(format: DSHLocalization.string("Took %lld min"), minutes)
                : String(format: DSHLocalization.string("Took %lld min %lld sec"), minutes, rest)
        }
        return String(format: DSHLocalization.string("Took %lld hr %lld min"),
                      minutes / 60, minutes % 60)
    }


}

struct ConversationView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack { ConversationView(sessionID: "preview-session") }
            .environmentObject(DSHAppModel.preview())
    }
}

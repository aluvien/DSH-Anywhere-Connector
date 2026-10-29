import SwiftUI
import Combine
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import UIKit

struct DSHStagedAttachment: Identifiable, Sendable, Codable, Equatable {
    let id: UUID
    let name: String
    let data: Data
    let isImage: Bool

    init(id: UUID = UUID(), name: String, data: Data, isImage: Bool) {
        self.id = id
        self.name = name
        self.data = data
        self.isImage = isImage
    }
}

private extension URL {
    /// Image extensions the composer treats as previewable photos.
    var isImageFile: Bool {
        ["png", "jpg", "jpeg", "heic"].contains(pathExtension.lowercased())
    }
}

/// Projects the latest concrete Harness activity for the active turn into the
/// concise status line above the composer.  Events from an earlier turn must
/// never make a newly running turn look active: the newest accepted user
/// message is the turn boundary and every candidate has to arrive after it.
///
/// A tool's completion is still useful activity while the model is deciding
/// its next step.  Previously the UI only considered tools whose status was
/// literally `running`, so the small gap after a completed tool incorrectly
/// fell through to "等待响应…" despite the Harness trail being visible.
enum DSHLiveTurnStatusProjection {
    static func trail(messages: [DSHChatMessage], tools: [DSHToolActivity]) -> String? {
        guard let turnStart = currentTurnStart(messages) else {
            // Without a sequence boundary we cannot distinguish this run
            // from a historical tool row, so retain the honest fallback.
            return nil
        }

        let currentTools = tools.filter { ($0.sequence ?? Int64.min) > turnStart }
        if let running = newest(currentTools.filter { $0.status.lowercased() == "running" }, by: \.sequence) {
            return DSHToolPresentation.headline(for: running)
        }

        // Ignore empty assistant frames (tool-call scaffolding).  They are
        // emitted by Harness before a tool call and do not describe useful
        // visible work.  Compare actual output/reasoning with a completed
        // tool by sequence, so the line mirrors the newest real trajectory.
        let assistantActivity = newest(messages.compactMap { message -> (message: DSHChatMessage, text: String)? in
            guard message.role == .assistant,
                  let sequence = message.sequence,
                  sequence > turnStart else { return nil }
            if !message.markdown.isEmpty {
                let preview = previewLine(message.markdown)
                return (message, preview.isEmpty ? "正在输出…" : "正在输出 · \(preview)")
            }
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                return (message, "思考中…")
            }
            return nil
        }, by: { $0.message.sequence })
        let completedTool = newest(currentTools.filter { $0.status.lowercased() != "running" }, by: \.sequence)

        switch (assistantActivity, completedTool) {
        case let (.some(activity), .some(tool)):
            if (activity.message.sequence ?? Int64.min) > (tool.sequence ?? Int64.min) {
                return activity.text
            }
            return "\(DSHToolPresentation.statusText(tool.status)) · \(DSHToolPresentation.headline(for: tool))"
        case let (.some(activity), .none):
            return activity.text
        case let (.none, .some(tool)):
            return "\(DSHToolPresentation.statusText(tool.status)) · \(DSHToolPresentation.headline(for: tool))"
        case (.none, .none):
            return nil
        }
    }

    /// Historical tools may retain this status after a turn has settled;
    /// only the authoritative turn state decides whether to show a live clock.
    static func hasRunningTool(messages: [DSHChatMessage], tools: [DSHToolActivity]) -> Bool {
        guard let turnStart = currentTurnStart(messages) else { return false }
        return tools.contains {
            ($0.sequence ?? Int64.min) > turnStart && $0.status.lowercased() == "running"
        }
    }

    static func shouldShow(turnState: String, messages: [DSHChatMessage],
                           tools: [DSHToolActivity]) -> Bool {
        turnState.lowercased() == "running"
    }

    private static func currentTurnStart(_ messages: [DSHChatMessage]) -> Int64? {
        messages.filter { $0.role == .user }.compactMap(\.sequence).max()
    }

    private static func newest<T>(_ values: [T], by sequence: (T) -> Int64?) -> T? {
        values.max { (sequence($0) ?? Int64.min) < (sequence($1) ?? Int64.min) }
    }

    private static func previewLine(_ text: String, limit: Int = 40) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return "" }
        return line.count > limit ? "…" + String(line.suffix(limit)) : String(line)
    }
}

/// A small tail capacity for a live assistant reply.  The capacity is based on
/// the real rendered reply, rather than an arbitrary number of lines: when a
/// chunk makes the reply taller, the same amount is released from the tail so
/// the transcript's total height stays almost unchanged.  The next chunk tops
/// the capacity back up from the observed growth rate.  Completion removes it
/// altogether.
///
/// This intentionally models only one temporary delta message.  A durable
/// completion has `replacesMessageId`, so it must never acquire a new reserve
/// during the brief interval before `turn.state.changed` settles.
struct DSHStreamingHeadroomPlan: Equatable {
    private(set) var streamID: String?
    private(set) var reservedHeight: CGFloat = 0
    private var measuredHeight: CGFloat?
    private var measuredWidth: CGFloat?
    private var recentGrowth: CGFloat = 0

    private static let minimumCapacity: CGFloat = 24
    private static let maximumCapacity: CGFloat = 96

    /// The outer bubble's stable height while its intrinsic Markdown content
    /// grows.  Keeping the capacity inside that row avoids the one-layout-pass
    /// grow/shrink cycle a trailing spacer would cause in the scroll view.
    var reservedReplyHeight: CGFloat? {
        guard let measuredHeight else { return nil }
        return measuredHeight + reservedHeight
    }

    mutating func begin(streamID: String?) {
        guard self.streamID != streamID else { return }
        self.streamID = streamID
        reservedHeight = 0
        measuredHeight = nil
        measuredWidth = nil
        recentGrowth = 0
    }

    /// Reserve the next observed amount before the next visual update.  The
    /// first size measurement seeds this from the actual reply height; later
    /// chunks use recent real vertical growth, with a deliberately tight cap.
    mutating func prepareForNextChunk(streamID: String?) {
        guard streamID != nil, streamID == self.streamID,
              let measuredHeight else { return }
        let target = targetCapacity(for: measuredHeight)
        // Do not refill after every wrapped line.  Doing that merely trades
        // tiny per-line jumps for a spacer that grows continuously.  Refill
        // only once the measured reservoir is almost exhausted.
        let lowWater = max(6, min(target * 0.2, recentGrowth * 0.4))
        if reservedHeight <= lowWater {
            reservedHeight = target
        }
    }

    /// Feed the rendered bubble's measured size.  Positive growth consumes
    /// exactly that much tail capacity; a temporary Markdown reflow that
    /// shrinks the row gives the capacity back.  This keeps the bottom stable
    /// through ordinary wrapping without guessing future paragraph length.
    mutating func record(streamID: String, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard self.streamID == streamID else {
            begin(streamID: streamID)
            measuredHeight = size.height
            measuredWidth = size.width
            reservedHeight = targetCapacity(for: size.height)
            return
        }

        guard let previousHeight = measuredHeight,
              let previousWidth = measuredWidth,
              abs(previousWidth - size.width) <= 0.5 else {
            measuredHeight = size.height
            measuredWidth = size.width
            recentGrowth = 0
            reservedHeight = targetCapacity(for: size.height)
            return
        }

        let delta = size.height - previousHeight
        measuredHeight = size.height
        measuredWidth = size.width
        if delta > 0 {
            recentGrowth = recentGrowth == 0 ? delta : (recentGrowth * 0.6 + delta * 0.4)
        }
        // `-delta` deliberately handles a temporary Markdown block reflow;
        // clamp so a malformed/large block can never create a blank screen.
        reservedHeight = min(Self.maximumCapacity, max(0, reservedHeight - delta))
    }

    private func targetCapacity(for height: CGFloat) -> CGFloat {
        // The first measured line is the only honest estimate before we have
        // an observed wrap.  Keeping roughly 1.6× that real row height gives
        // the next one or two wraps room without a fixed "N lines" rule.
        let fromRenderedReply = recentGrowth == 0 ? height * 1.6 : height * 0.4
        let fromObservedGrowth = recentGrowth * 2.2
        return min(Self.maximumCapacity,
                   max(Self.minimumCapacity, fromRenderedReply, fromObservedGrowth))
    }
}

private struct DSHStreamMessageMeasurement: Equatable {
    let streamID: String
    let size: CGSize
}

private struct DSHStreamMessageMeasurementKey: PreferenceKey {
    static let defaultValue: DSHStreamMessageMeasurement? = nil

    static func reduce(value: inout DSHStreamMessageMeasurement?,
                       nextValue: () -> DSHStreamMessageMeasurement?) {
        if let next = nextValue() { value = next }
    }
}

struct DSHActiveStreamingMessage: Equatable {
    /// The transient delta ID is stable through the final canonical replace.
    let streamID: String
    /// The row currently rendered on screen; it changes only at completion.
    let renderedMessageID: String
}

enum DSHStreamingMessageProjection {
    static func active(messages: [DSHChatMessage], turnState: String) -> DSHActiveStreamingMessage? {
        guard turnState.lowercased() == "running",
              let message = messages.last,
              message.role == .assistant,
              message.id.hasPrefix("stream-"),
              !message.markdown.isEmpty,
              message.replacesMessageId == nil else { return nil }
        // A transient frame is always emitted after the accepted user turn.
        // Retaining this boundary prevents an old, pre-stream legacy reply
        // from reserving space merely because another tool starts later.
        if let latestUserSequence = messages.filter({ $0.role == .user })
            .compactMap(\.sequence).max(),
           (message.sequence ?? Int64.min) <= latestUserSequence {
            return nil
        }
        return DSHActiveStreamingMessage(streamID: message.id, renderedMessageID: message.id)
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

/// Only route commands whose semantics are known until a host command catalog
/// is available. Ordinary messages and unknown slash text stay as prompts.
func dshNativeComposerCommand(_ text: String, knownCommands: Set<String>? = nil) -> String? {
    let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard line.first == "/" else { return nil }
    let name = line.dropFirst().prefix { !$0.isWhitespace }
    return (knownCommands ?? ["plan", "goal"]).contains(String(name)) ? line : nil
}

func dshComposerCommands(_ catalog: DSHCommandCatalog?) -> [(id: String, gloss: String, icon: String)] {
    guard let catalog else { return DSHSlashCommands }
    let hostNames = Set(catalog.commands.map(\.name))
    return catalog.commands.map { (id: $0.name, gloss: $0.description, icon: "terminal") }
        + (catalog.skills ?? []).filter { !hostNames.contains($0.name) }.map {
            (id: $0.name, gloss: $0.description, icon: "sparkles")
        }
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
    var onReference: (() -> Void)? = nil
    @State private var isPresented = false
    @State private var pendingPicker: (() -> Void)?

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
                        icon: .file, afterDismissal: true, action: onFile)
                if onCamera != nil && DSHCameraPicker.isAvailable {
                    menuRow(title: "相机", subtitle: "拍摄一张照片",
                            icon: .camera, afterDismissal: true, action: { onCamera?() })
                }
                menuRow(title: "照片", subtitle: "从相簿选取",
                        icon: .photos, afterDismissal: true, action: onPhoto)
                if let onReference {
                    menuRow(title: "引用", subtitle: "电脑上的文件、目录或会话", icon: .file, afterDismissal: true, action: onReference)
                }
            }
            .padding(.vertical, 8)
            .frame(width: 280)
            .presentationCompactAdaptation(.popover)
            .onDisappear {
                guard let action = pendingPicker else { return }
                pendingPicker = nil
                // Present only after the menu has left the presentation tree.
                Task { @MainActor in
                    await Task.yield()
                    action()
                }
            }
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
                         afterDismissal: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            if afterDismissal { pendingPicker = action }
            isPresented = false
            if !afterDismissal { action() }
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

    func pauseFollowing() { setFollowing(false) }

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
        // The same scroll view may have been found before it entered a
        // window. attach() correctly coalesces that identity, so request the
        // initial pin again at the mounted lifecycle boundary.
        if window != nil { coordinator?.schedulePin() }
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
                    commands: dshComposerCommands(model.commandCatalog(for: sessionID)),
                    onCommand: { command in
                        showCommandMenu = false
                        handleMenuCommand(command)
                    },
                    onDismiss: { showCommandMenu = false }
                )
                .onAppear { model.requestCommands(for: sessionID) }
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
                DSHRemoteFilesPanel(sessionID: sessionID)
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
                    appendDraftAttachments([DSHStagedAttachment(name: "camera.jpg",
                                                                  data: optimized,
                                                                  isImage: true)])
                }
            }
    }

    private func appendDraftAttachments(_ values: [DSHStagedAttachment]) {
        let remaining = max(0, 16 - draftAttachments.count)
        let accepted = values.filter { $0.data.count <= 10 * 1024 * 1024 }.prefix(remaining)
        draftAttachments.append(contentsOf: accepted)
        if accepted.count < values.count {
            model.errorMessage = draftAttachments.count >= 16
                ? "一条消息最多包含 16 个附件。"
                : "附件必须不超过 10 MiB，过大的文件未添加。"
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
    let streamingMessageID: String?
    let isRunning: Bool
    let sessionID: String
    let initialVisibleLimit: Int
    @Binding var visibleSectionLimit: Int
    @Binding var selectedPhotos: [PhotosPickerItem]
    let model: DSHAppModel
    let pinToBottom: () -> Void
    let prepareStreamingHeadroom: (String?) -> Void
    let resetStreamingHeadroom: () -> Void
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
                prepareStreamingHeadroom(streamingMessageID)
                pinToBottom()
            }
            .onChange(of: streamingMessageID) { _, activeID in
                // The durable final message keeps the old delta ID in
                // `replacesMessageId`, but it is no longer stream content.
                // Drop the tail immediately even if its turn has another
                // tool step still running.
                if activeID == nil { resetStreamingHeadroom() }
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
    var initialLocation: DSHSearchHit? = nil
    @State private var showHistorySearch = false
    @State private var showSchedules = false
    @State private var locationRequest: DSHSearchHit?
    @State private var locationRevision = UUID()
    @State private var historyLoading = false
    @State private var historyError: String?
    @State private var focusedHistory: DSHHistoryFocus?
    @State private var highlightedSection: String?

    @State private var showFileImporter = false
    @State private var showReferencePicker = false
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
    @State private var showJobsPanel = false
    @State private var showSubagentsPanel = false
    @State private var showWorkflowsPanel = false
    @State private var showExecutionPanel = false
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
    @State private var isForking = false
    @State private var forkedSessionID: String?
    @State private var didRefresh = false
    /// Tracks the composer field so the keyboard can be dismissed explicitly.
    @FocusState private var isDraftFocused: Bool
    /// False once the reader scrolls away from the newest output, so auto-follow
    /// never fights a manual scroll.
    @State private var isFollowingLatest = true
    /// A measured, temporary capacity after the live reply.  It is consumed as
    /// the reply wraps and removed as soon as the durable answer replaces it.
    @State private var streamingHeadroom = DSHStreamingHeadroomPlan()
    /// When this device first saw the current turn run. Drives the live
    /// elapsed clock above the composer; cleared when the turn settles.
    @State private var turnStartedAt: Date?
    private static let bottomAnchor = "conversation-bottom"

    private var session: DSHSessionSummary? { model.sessions.first { $0.id == sessionID } }
    private var isRunning: Bool { model.turnState(for: sessionID).lowercased() == "running" }
    /// Activity is scoped to the newest accepted user turn, not merely any
    /// historical tool in this session.  This lets a completed tool keep the
    /// trail alive between Harness steps without leaking an older run into the
    /// status line.
    private var liveTurnTrail: String? {
        DSHLiveTurnStatusProjection.trail(messages: model.messages(for: sessionID),
                                           tools: model.tools(for: sessionID))
    }
    private var showsLiveTurnStatus: Bool {
        DSHLiveTurnStatusProjection.shouldShow(turnState: model.turnState(for: sessionID),
                                                messages: model.messages(for: sessionID),
                                                tools: model.tools(for: sessionID))
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

    /// Only a delta message is eligible.  A completed canonical message can
    /// arrive a fraction before the turn-state event, and must not restart the
    /// spacer while a later Harness tool is still running.
    private var activeStreamingMessage: DSHActiveStreamingMessage? {
        DSHStreamingMessageProjection.active(messages: model.messages(for: sessionID),
                                             turnState: model.turnState(for: sessionID))
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
    private func transcriptSectionView(_ section: DSHTranscriptSection, proxy: ScrollViewProxy) -> some View {
        switch section {
        case .turn(let block, _):
            if block.isUserTurn {
                MessageBubble(sessionID: sessionID, message: block.messages[0]).id(section.id)
            } else {
                AssistantTurnView(sessionID: sessionID,
                                  block: block,
                                  isTaskRunning: isRunning && block.taskTimeline?.promptID == model.messages(for: sessionID).last(where: { $0.role == .user })?.id,
                                  streamingMessage: activeStreamingMessage,
                                  streamingMinimumHeight: streamingHeadroom.streamID == activeStreamingMessage?.streamID
                                    ? streamingHeadroom.reservedReplyHeight : nil,
                                  onBranch: { createBranchSession(at: block.messages.last?.nativeSequence) }).id(section.id)
            }
        case .row(let entry):
            switch entry {
            case .historyGap(let range):
                VStack(alignment: .leading, spacing: 8) {
                    Text("此处还有未加载的历史记录").font(.caption).foregroundStyle(.secondary)
                    Button("从此处继续加载") {
                        let sections = visibleTranscriptSections
                        let index = sections.firstIndex(where: { $0.id == section.id })
                        let anchor = index.flatMap { $0 + 1 < sections.count ? sections[$0 + 1].id : nil }
                        Task { await loadRemoteHistory(beforeSeq: range.upper + 1, proxy: proxy, anchorID: anchor) }
                    }
                        .disabled(historyLoading || model.connectionState != .connected)
                }.frame(maxWidth: .infinity).padding(.vertical, 12).id(section.id)
            case .turn(let block):
                if block.isUserTurn {
                    MessageBubble(sessionID: sessionID, message: block.messages[0]).id(section.id)
                } else {
                    AssistantTurnView(sessionID: sessionID,
                                      block: block,
                                      isTaskRunning: false,
                                      streamingMessage: activeStreamingMessage,
                                      streamingMinimumHeight: streamingHeadroom.streamID == activeStreamingMessage?.streamID
                                        ? streamingHeadroom.reservedReplyHeight : nil,
                                      onBranch: { createBranchSession(at: block.messages.last?.nativeSequence) }).id(section.id)
                }
            case .tool(let tool):
                // A tool with no preceding assistant turn
                // (history edge): keep it visible standalone.
                ToolActivityCard(tool: tool, sessionID: sessionID).id(section.id)
            case .command(let result):
                CommandResultCard(result: result).id(section.id)
            case .modelChange(let notice):
                ModelChangeCard(notice: notice).id(section.id)
            case .workflow(let run):
                DSHWorkflowRunCard(sessionID: sessionID, run: run).id(section.id)
            case .execution(let notice):
                DSHExecutionNoticeCard(sessionID: sessionID, notice: notice).id(section.id)
            }
        }
    }

    /// Pages the render window back by one page, keeping the old top row
    /// pinned under the header so the viewport does not jump. Called by the
    /// tap button and by the top sentinel (scroll-to-top auto-loads).
    private func loadEarlierSections(proxy: ScrollViewProxy) {
        guard hiddenSectionCount > 0 else {
            guard !historyLoading else { return }
            Task { await loadRemoteHistory(beforeSeq: model.historyCoverage(for: sessionID)?.nextBefore, proxy: proxy) }
            return
        }
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
        if hiddenSectionCount > 0 || model.historyCoverage(for: sessionID)?.nextBefore != nil || model.historyCoverage(for: sessionID) == nil {
            // Scrolling to the very top pages automatically; appearing
            // without a disappear cycle does not refire, so this cannot loop.
            Color.clear
                .frame(height: 1)
                .onAppear { if hiddenSectionCount > 0 { loadEarlierSections(proxy: proxy) } }
            HStack {
                Spacer(minLength: 0)
                Button {
                    loadEarlierSections(proxy: proxy)
                } label: {
                    loadEarlierLabel
                }
                .accessibilityLabel("加载更早的对话内容")
                .disabled(historyLoading || (hiddenSectionCount == 0 && model.connectionState != .connected))
                Spacer(minLength: 0)
            }
        }
        if historyLoading { ProgressView("读取电脑历史…") }
        if let historyError { Text(historyError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
    }

    private var loadEarlierLabel: some View {
        Text(hiddenSectionCount > 0 ? "↑ 加载更早 \(hiddenSectionCount) 段" : model.historyCoverage(for: sessionID) == nil ? "读取电脑上的完整历史" : "↑ 从电脑加载更早记录")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .padding(.vertical, 8)
    }

    private func loadRemoteHistory(beforeSeq: Int64?, proxy: ScrollViewProxy?, anchorID: String? = nil) async {
        guard !historyLoading else { return }
        historyLoading = true; historyError = nil
        scrollCoordinator.pauseFollowing(); isFollowingLatest = false
        let anchor = anchorID ?? windowedTranscriptSections.first?.id
        let oldCount = visibleTranscriptSections.count
        defer { historyLoading = false }
        do {
            _ = try await model.historyPage(sessionID: sessionID, beforeSeq: beforeSeq)
            try Task.checkCancellation()
            visibleSectionLimit += max(Self.transcriptPageSize, visibleTranscriptSections.count - oldCount)
            if let anchor, let proxy { DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) } }
        } catch is CancellationError { }
        catch { historyError = error.localizedDescription }
    }

    private func locateHistory(_ hit: DSHSearchHit, proxy: ScrollViewProxy) async {
        guard let seq = hit.nativeSequence else { return }
        historyError = nil; historyLoading = true
        scrollCoordinator.pauseFollowing(); isFollowingLatest = false
        defer { historyLoading = false }
        do {
            let page = try await model.historyPage(sessionID: sessionID, atSeq: seq)
            try Task.checkCancellation()
            if let index = visibleTranscriptSections.firstIndex(where: { $0.contains(nativeSequence: seq) }) {
                let id = visibleTranscriptSections[index].id
                visibleSectionLimit = max(visibleSectionLimit, visibleTranscriptSections.count - index + 2)
                highlightedSection = id
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
                // Tools and non-message hits can live inside a collapsed
                // chain. The explicit search selection opens their exact data.
                if hit.type != "user/message" && hit.type != "assistant/message" { focusedHistory = page.focus }
            } else { focusedHistory = page.focus }
        } catch is CancellationError { }
        catch { historyError = error.localizedDescription }
    }

    /// Pending approval/question cards inline in the transcript. Extracted
    /// from `body` so their closures don't share its type-check budget.
    @ViewBuilder
    private func inlineDecisionCards() -> some View {
        ForEach(model.pendingApprovals.filter { $0.sessionId == sessionID }) { approval in
            ApprovalCard(approval: approval, savedDecision: model.approvalDecisionDraft(for: approval)) { allow in
                try await model.decide(approval, allow: allow)
            }
        }
        ForEach(model.pendingQuestions.filter { $0.sessionId == sessionID }) { question in
            QuestionCard(request: question, savedDraft: model.questionDraft(for: question),
                         onDraftChange: { model.saveQuestionDraft($0, for: question) }, onCancel: {
                try await model.cancelQuestion(question)
                isDraftFocused = true
            }) { answers in
                try await model.answer(question, answers: answers)
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
                    transcriptSectionView(section, proxy: proxy)
                        .overlay { if highlightedSection == section.id { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.6), lineWidth: 1).allowsHitTesting(false) } }
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
        .onPreferenceChange(DSHStreamMessageMeasurementKey.self) { measurement in
            guard let measurement else { return }
            updateStreamingHeadroom(with: measurement)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            transcriptScrollView(proxy: proxy)
                .dshTopScrollBar {
                    happyConversationHeader
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    composer(proxy: proxy)
                        .padding(.bottom, 8)
                }
            .background(Color(.systemBackground))
            .onAppear {
                model.setConversationVisible(sessionID, visible: true)
                scrollCoordinator.followingChanged = { following in
                    withAnimation(.easeInOut(duration: 0.25)) { isFollowingLatest = following }
                }
                if initialLocation == nil { scrollCoordinator.schedulePin() }
                else { scrollCoordinator.pauseFollowing(); isFollowingLatest = false; locationRequest = initialLocation; locationRevision = UUID() }
            }
            .onDisappear {
                model.setConversationVisible(sessionID, visible: false)
                scrollCoordinator.followingChanged = nil
            }
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
            .task(id: locationRevision) {
                if let hit = locationRequest { await locateHistory(hit, proxy: proxy) }
            }
            // Auto-follow only while the reader is already at the newest output.
            // Scrolling back disarms it, so incoming work never yanks the view.
            .navigationDestination(isPresented: Binding(get: { forkedSessionID != nil }, set: { if !$0 { forkedSessionID = nil } })) {
                if let id = forkedSessionID { ConversationView(sessionID: id) }
            }
            .modifier(ConversationObservers(messageCount: model.messages(for: sessionID).count,
                                            sessionUpdatedAt: session?.updatedAt,
                                            entriesCount: transcriptEntries.count,
                                            streamingSignature: latestStreamingSignature,
                                            streamingMessageID: activeStreamingMessage?.streamID,
                                            isRunning: isRunning,
                                            sessionID: sessionID,
                                            initialVisibleLimit: Self.transcriptInitialLimit,
                                            visibleSectionLimit: $visibleSectionLimit,
                                            selectedPhotos: $selectedPhotos,
                                            model: model,
                                            pinToBottom: { self.scrollToLatest(proxy) },
                                            prepareStreamingHeadroom: { self.prepareStreamingHeadroom(for: $0) },
                                            resetStreamingHeadroom: { self.resetStreamingHeadroom() },
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
            .sheet(isPresented: $showJobsPanel) {
                DSHJobsPanel(sessionID: sessionID).environmentObject(model)
            }
            .sheet(isPresented: $showReferencePicker) {
                DSHReferencePicker(sessionID: sessionID) { model.draft = dshAppendReference($0, to: model.draft) }
            }
            .sheet(isPresented: $showSubagentsPanel) {
                DSHSubagentsPanel(parentID: sessionID).environmentObject(model)
            }
            .sheet(isPresented: $showWorkflowsPanel) { DSHWorkflowsPanel(sessionID: sessionID).environmentObject(model) }
            .sheet(isPresented: $showExecutionPanel) { DSHExecutionPanel(sessionID: sessionID).environmentObject(model) }
            .sheet(isPresented: $showHistorySearch) { DSHHistorySearchPanel(sessionID: sessionID) { locationRequest = $0; locationRevision = UUID() }.environmentObject(model) }
            .sheet(isPresented: $showSchedules) { DSHSchedulePanel(sessionID: sessionID).environmentObject(model) }
            .sheet(item: $focusedHistory) { DSHHistoryFocusView(sessionID: sessionID, focus: $0).environmentObject(model) }
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
                    Button { showExecutionPanel = true } label: { Label("执行轨迹", systemImage: "list.bullet.rectangle") }
                    Button { showHistorySearch = true } label: { Label("搜索对话", systemImage: "magnifyingglass") }
                    Button { showSchedules = true } label: { Label("定时提醒", systemImage: "clock.badge") }
                    Button { showFilesPanel = true } label: {
                        Label("文件", systemImage: "folder")
                    }
                    Button { showSubagentsPanel = true } label: {
                        Label("子任务", systemImage: "person.2")
                    }
                    if !model.workflows(for: sessionID).isEmpty {
                        Button { showWorkflowsPanel = true } label: { Label("工作流记录", systemImage: "point.3.connected.trianglepath.dotted") }
                    }
                    if let jobs = model.jobsState(for: sessionID), !jobs.jobs.isEmpty {
                        Button { showJobsPanel = true } label: {
                            Label("后台任务 · \(jobs.jobs.filter { $0.status == "running" || $0.status == "stopping" }.count) 运行中", systemImage: "gearshape.2")
                        }
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

            if let plan = model.planState(for: sessionID), plan.active || plan.pending == true {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(plan.active ? "计划模式" : "正在切换计划模式", systemImage: "list.clipboard")
                        if plan.available == false { Text("状态待同步").font(.caption).foregroundStyle(.secondary) }
                        else if plan.pending == true {
                            Text(plan.active ? "等待下一步退出计划模式" : "等待下一步进入计划模式")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("退出") { model.executeCommand("/plan off", for: sessionID) }
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(model.connectionState != .connected || plan.available == false)
                }
                .font(.subheadline)
                .padding(10)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            if let todo = model.todoState(for: sessionID), !todo.todos.isEmpty {
                DisclosureGroup {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(todo.todos, id: \.content) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: item.status == "completed" ? "checkmark.circle.fill" : item.status == "in_progress" ? "circle.dotted" : "circle")
                                        .foregroundStyle(item.status == "completed" ? Color.green : Color.accentColor)
                                    Text(item.content)
                                        .foregroundStyle(item.status == "completed" ? .secondary : .primary)
                                        .textSelection(.enabled)
                                }
                                .font(.subheadline)
                                .accessibilityLabel("\(item.content)，\(item.status == "completed" ? "已完成" : item.status == "in_progress" ? "进行中" : "待处理")")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    }
                    .frame(maxHeight: 220)
                } label: {
                    Text("待办 · \(todo.todos.filter { $0.status == "completed" }.count)/\(todo.todos.count) 已完成")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            if model.goalState(for: sessionID)?.goal != nil { DSHGoalCard(sessionID: sessionID) }

            // Live turn status rides above the input card while work happens,
            // so a reader who scrolled away still sees that work is happening
            // (and what it is doing) instead of a frozen screen. Gated on
            // current-turn activity. A running tool also keeps this visible
            // if its turn-state update arrives late; a just-finished Harness
            // step remains descriptive while that turn is still running.
            if showsLiveTurnStatus {
                liveTurnStatus
            }

            // Queued prompts bubble: prompts this device queued behind the
            // run, newest last. One shows its text, several show the count;
            // tapping opens the detail list. Entries retire when accepted.
            if !model.queuedPrompts(for: sessionID).isEmpty || model.serverQueue(for: sessionID)?.items.isEmpty == false {
                queuedPromptBubble
            }

            // Failed send: the prompt never got its acceptance. Says whether
            // it died locally or on the Mac side, and offers a retry with the
            // original text (and receipts) intact.
            if let failed = model.failedSend(for: sessionID) {
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
                    Button("重试") { model.retryFailedSend(requestID: failed.id) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Button {
                        model.dismissFailedSend(requestID: failed.id)
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

            if let failedInitial = model.failedInitialMessage(for: sessionID) {
                HStack(spacing: 8) {
                    Image(systemName: "paperclip.circle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("首条消息发送失败")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(failedInitial.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Button("重试") { model.retryFailedInitialMessage(failedInitial) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Button { model.dismissFailedInitialMessage(failedInitial) } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("关闭首条消息失败提示")
                }
                .padding(10)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("首条消息发送失败：\(failedInitial.text)")
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
                          slashCommands: dshComposerCommands(model.commandCatalog(for: sessionID)),
                          onSlashCommand: { command in
                              model.draft = dshCompleteSlashCommand(command, in: model.draft)
                          }) {
            if model.collapseComposerControls {
                DSHComposerQuickActionsMenu(
                onCommand: { command in
                    if commandNeedsInput(command) { insertCommandAtHead(command) }
                    else { model.executeCommand("/\(command)", for: sessionID) }
                },
                onPhoto: { showPhotoPicker = true },
                onFile: { showFileImporter = true },
                    onCamera: { showCamera = true }, onReference: { showReferencePicker = true }
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
                    Menu {
                        Button("从手机添加文件") { showFileImporter = true }
                        Button("引用电脑文件或会话") { showReferencePicker = true }
                    } label: {
                        Image(systemName: "paperclip").frame(width: 34, height: 34)
                    }
                    .accessibilityLabel("文件与引用")
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

    /// These shortcuts prepare a draft so the user can add a task or choose
    /// a subcommand. Bare /plan and /goal remain valid when submitted.
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

    /// Newest concrete activity in this user turn.  A finished tool remains
    /// meaningful between Harness steps, rather than collapsing to a generic
    /// waiting label before the next event arrives.
    private var liveTrailText: String {
        liveTurnTrail ?? "等待响应…"
    }

    /// Queue bubble above the input card, pinned right. One queued prompt
    /// shows its text, several collapse to a count; tapping opens the detail
    /// list. Edit/cancel of server-side queued items needs a protocol
    /// addition (`session/updateQueue`); until then this mirrors what this
    /// device sent and retires entries on acceptance.
    @ViewBuilder
    private var queuedPromptBubble: some View {
        let queued = model.queuedPrompts(for: sessionID)
        let serverItems = model.serverQueue(for: sessionID)?.items ?? []
        let count = queued.count + serverItems.count
        if count > 0 {
            HStack {
                Spacer(minLength: 0)
                Button { showQueuedList = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 12, weight: .medium))
                        if count == 1 {
                            Text(queued.first?.text ?? serverItems.first?.text ?? "排队消息")
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("\(count)条排队")
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
                    count == 1 ? "排队中的消息" : "\(count)条排队消息，查看详情")
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

    private func prepareStreamingHeadroom(for streamID: String?) {
        var plan = streamingHeadroom
        if plan.streamID != streamID { plan.begin(streamID: streamID) }
        plan.prepareForNextChunk(streamID: streamID)
        guard plan != streamingHeadroom else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) { streamingHeadroom = plan }
    }

    private func updateStreamingHeadroom(with measurement: DSHStreamMessageMeasurement) {
        guard activeStreamingMessage?.streamID == measurement.streamID else { return }
        var plan = streamingHeadroom
        plan.record(streamID: measurement.streamID, size: measurement.size)
        guard plan != streamingHeadroom else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) { streamingHeadroom = plan }
    }

    private func resetStreamingHeadroom() {
        guard streamingHeadroom.streamID != nil || streamingHeadroom.reservedHeight > 0 else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) { streamingHeadroom.begin(streamID: nil) }
    }

    /// Turn-state flips drive the live clock and re-anchor the transcript.
    /// Extracted from `body` so the repin closures don't share its
    /// type-check budget.
    private func handleRunningChange(_ running: Bool, proxy: ScrollViewProxy) {
        if running {
            if turnStartedAt == nil { turnStartedAt = .now }
        } else {
            turnStartedAt = nil
            resetStreamingHeadroom()
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
        // Validate before clearing either editor. The Relay schema rejects an
        // overlong prompt, but that is a request-level error and must not make
        // the user lose a draft that can still be edited locally.
        guard model.validatePromptText(trimmed) else { return }
        guard staged.count <= 16 else {
            model.errorMessage = "一条消息最多包含 16 个附件。"
            return
        }
        guard staged.allSatisfy({ $0.data.count <= 10 * 1024 * 1024 }) else {
            model.errorMessage = "附件必须不超过 10 MiB，请移除过大的文件后重试。"
            return
        }
        if let line = dshNativeComposerCommand(text, knownCommands: model.commandCatalog(for: sessionID).map { Set($0.commands.map(\.name)) }) {
            let commandName = String(line.dropFirst().prefix { !$0.isWhitespace })
            guard staged.isEmpty || model.commandCatalog(for: sessionID)?.commands.first(where: { $0.name == commandName })?.input?.attachments == true else {
                model.errorMessage = "这条命令未声明支持附件，请移除附件后重试。"
                return
            }
            isSending = true
            let generation = model.currentMachineGeneration
            let expectedMachineID = model.machineID
            Task { @MainActor in
                defer { isSending = false }
                do {
                    if staged.isEmpty {
                        try await model.executeComposerCommand(line, for: sessionID,
                                                           machineGeneration: generation,
                                                           expectedMachineID: expectedMachineID)
                    } else {
                        guard await model.preparePromptPersistence(expectedMachineGeneration: generation,
                                                                    expectedMachineID: expectedMachineID) else { return }
                        let requestID = model.stagedPromptRequestID(text: line, attachments: staged, sessionID: sessionID)
                            ?? UUID().uuidString
                        guard try await model.sendStagedPromptPersisted(line, attachments: staged, to: sessionID,
                            mode: "command", requestId: requestID, expectedMachineGeneration: generation,
                            expectedMachineID: expectedMachineID) else { return }
                    }
                    if model.currentMachineGeneration == generation,
                       model.machineID == expectedMachineID, model.draft == text, draftAttachments == staged {
                        model.draft = ""
                        draftAttachments = []
                    }
                } catch {
                    if model.currentMachineGeneration == generation, model.machineID == expectedMachineID {
                        model.errorMessage = error.localizedDescription
                    }
                }
            }
            return
        }
        let wasRunning = isRunning
        // Text-only queue while busy stays on the device (editable,
        // cancellable, auto-fired when the turn settles). Anything with
        // attachments — and every steer — goes to the server immediately.
        if wasRunning && mode == "queue" && staged.isEmpty {
            // An edited text-only queue submission supersedes any older
            // preparing attachment transaction for this session.  That old
            // draft was never sent and must not resume silently later.
            let generation = model.currentMachineGeneration
            let expectedMachineID = model.machineID
            isSending = true
            Task { @MainActor in
                guard model.isCurrentMachineGeneration(generation),
                      model.machineID == expectedMachineID,
                      await model.supersedePreparingPromptTransactions(for: sessionID) else {
                    isSending = false
                    return
                }
                model.holdQueuedPrompt(text: trimmed, for: sessionID)
                isDraftFocused = false
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
                model.draft = ""
                isSending = false
            }
            return
        }
        let requestId = staged.isEmpty
            ? UUID().uuidString
            : (model.stagedPromptRequestID(text: trimmed, attachments: staged, sessionID: sessionID)
                ?? UUID().uuidString)
        // Keep the editor's contents until the prompt transaction is durably
        // accepted. `isSending` prevents a double tap while uploads are in
        // flight; clearing earlier would lose the draft if the journal cannot
        // be written.
        isDraftFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        isSending = true
        let machineGeneration = model.currentMachineGeneration
        let expectedMachineID = model.machineID
        Task { @MainActor in
            guard model.isCurrentMachineGeneration(machineGeneration),
                  model.machineID == expectedMachineID else {
                isSending = false
                return
            }
            guard await model.supersedePreparingPromptTransactions(for: sessionID,
                                                                    keeping: requestId) else {
                model.errorMessage = "无法保存待处理请求，暂不安全发送。"
                isSending = false
                return
            }
            guard await model.preparePromptPersistence(expectedMachineGeneration: machineGeneration,
                                                       expectedMachineID: expectedMachineID) else {
                isSending = false
                return
            }
            do {
                let sent: Bool
                if staged.isEmpty {
                    sent = await model.sendPromptPersisted(
                        text, attachments: [], to: sessionID, mode: mode, requestId: requestId,
                        expectedMachineGeneration: machineGeneration,
                        expectedMachineID: expectedMachineID)
                } else {
                    sent = try await model.sendStagedPromptPersisted(
                        text, attachments: staged, to: sessionID, mode: mode,
                        requestId: requestId,
                        expectedMachineGeneration: machineGeneration,
                        expectedMachineID: expectedMachineID)
                }
                guard sent else {
                    isSending = false
                    return
                }
                if wasRunning && mode == "queue" {
                    model.noteQueuedPrompt(text: trimmed, mode: mode, requestId: requestId, for: sessionID)
                }
                model.draft = ""
                draftAttachments = []
            } catch {
                guard model.isCurrentMachineGeneration(machineGeneration) else {
                    isSending = false
                    return
                }
                guard model.machineID == expectedMachineID else {
                    isSending = false
                    return
                }
                model.draft = text
                draftAttachments = staged
                model.errorMessage = error.localizedDescription
            }
            guard model.isCurrentMachineGeneration(machineGeneration),
                  model.machineID == expectedMachineID else {
                isSending = false
                return
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

    private func appendDraftAttachments(_ values: [DSHStagedAttachment]) {
        let remaining = max(0, 16 - draftAttachments.count)
        let accepted = values.filter { $0.data.count <= 10 * 1024 * 1024 }.prefix(remaining)
        draftAttachments.append(contentsOf: accepted)
        if accepted.count < values.count {
            model.errorMessage = draftAttachments.count >= 16
                ? "一条消息最多包含 16 个附件。"
                : "附件必须不超过 10 MiB，过大的文件未添加。"
        }
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
            appendDraftAttachments([attachment])
        }
    }

    private func handleMenuCommand(_ command: String) {
        if command == "permission" { showPermissionPicker = true }
        else if command == "model" { showModelPicker = true }
        else if commandNeedsInput(command) { insertCommandAtHead(command) }
        else { model.executeCommand("/\(command)", for: sessionID) }
    }

    private func commandNeedsInput(_ command: String) -> Bool {
        if let entry = model.commandCatalog(for: sessionID)?.commands.first(where: { $0.name == command }) {
            return entry.input != nil
        }
        if model.commandCatalog(for: sessionID)?.skills?.contains(where: { $0.name == command }) == true { return true }
        return Self.commandNeedsArguments(command)
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
                    let before = draftAttachments.count
                    appendDraftAttachments([attachment])
                    if draftAttachments.count > before { staged += 1 }
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

    /// The Host selects a completed-turn boundary and inherits its log.
    private func createBranchSession(at nativeSequence: Int64?) {
        guard !isForking else { return }
        guard let nativeSequence else {
            model.errorMessage = "这条回答缺少原始历史位置，请刷新会话后再创建分支。"
            return
        }
        isForking = true
        let generation = model.currentMachineGeneration
        Task { @MainActor in
            defer { isForking = false }
            do {
                let id = try await model.forkSession(sessionID, atSeq: nativeSequence)
                if model.currentMachineGeneration == generation { forkedSessionID = id }
            } catch {
                if model.currentMachineGeneration == generation { model.errorMessage = error.localizedDescription }
            }
        }
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
    var commands: [(id: String, gloss: String, icon: String)] = DSHSlashCommands
    let onCommand: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Commands") {
                    ForEach(commands, id: \.id) { item in
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

private struct DSHGoalCard: View {
    let sessionID: String
    @EnvironmentObject private var model: DSHAppModel
    @State private var editingGoal: DSHGoalState.Goal?
    @State private var busy = false
    @State private var operationError: String?
    @State private var showObjective = false

    var body: some View {
        if let state = model.goalState(for: sessionID), let goal = state.goal {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("目标 · \(phaseLabel(goal.phase))", systemImage: "target")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if busy { ProgressView() }
                    Menu {
                        if goal.phase != "complete" {
                            Button("编辑目标与轮次") { editingGoal = goal }
                            if goal.phase == "active" { Button("暂停") { mutate(goal, action: "pause") } }
                            if goal.phase != "active" || state.activation == "disarmed" {
                                Button("恢复") { mutate(goal, action: "resume") }
                            }
                            Button("标记完成") { mutate(goal, action: "complete") }
                        }
                        Button("清除目标", role: .destructive) { mutate(goal, action: "clear") }
                        Button("刷新目标状态") { model.requestGoalState(for: sessionID) }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                        .disabled(busy || model.connectionState != .connected)
                }
                Button { showObjective = true } label: {
                    Text(goal.objective).font(.subheadline).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityHint("查看完整目标")
                Text("轮次 \(state.roundsStarted)/\(goal.maxGoalRounds) · \(activationLabel(state.activation))")
                    .font(.caption).foregroundStyle(.secondary)
                if let reason = goal.blockedReason { Text(reason.message).font(.caption).foregroundStyle(.secondary) }
                if let operationError { Text(operationError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .task(id: goal.id) { model.requestGoalState(for: sessionID) }
            .sheet(item: $editingGoal) { snapshot in DSHGoalEditor(sessionID: sessionID, goal: snapshot).environmentObject(model) }
            .sheet(isPresented: $showObjective) {
                NavigationStack {
                    ScrollView { MarkdownBlockText(text: goal.objective).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading) }
                        .navigationTitle("完整目标").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showObjective = false } } }
                }
            }
        }
    }
    private func phaseLabel(_ phase: String) -> String {
        switch phase { case "active": "已启用"; case "paused": "已暂停"; case "blocked": "受阻"; case "complete": "已完成"; default: phase }
    }
    private func activationLabel(_ activation: String?) -> String {
        switch activation { case "armed": "自动推进已启用"; case "disarmed": "自动推进未启用"; default: "自动推进状态待同步" }
    }
    private func mutate(_ goal: DSHGoalState.Goal, action: String) {
        guard !busy else { return }
        busy = true
        operationError = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await model.updateGoal(goal, in: sessionID, action: action) }
            catch { operationError = error.localizedDescription }
        }
    }
}

struct DSHGoalEditor: View {
    let sessionID: String
    @State private var base: DSHGoalState.Goal
    @State private var objective: String
    @State private var rounds: String
    @State private var busy = false
    @State private var operationError: String?
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss

    init(sessionID: String, goal: DSHGoalState.Goal) {
        self.sessionID = sessionID
        _base = State(initialValue: goal)
        _objective = State(initialValue: goal.objective)
        _rounds = State(initialValue: String(goal.maxGoalRounds))
    }
    private var latest: DSHGoalState.Goal? { model.goalState(for: sessionID)?.goal }
    private var conflicted: Bool { latest?.id != base.id || latest?.revision != base.revision }
    private var valid: Bool {
        !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && objective.utf16.count <= 100_000
            && Int(rounds).map { $0 > 0 && $0 <= 9_007_199_254_740_991 } == true
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("目标") { TextEditor(text: $objective).frame(minHeight: 150).disabled(busy) }
                Section("自动推进的总轮次上限") {
                    TextField("轮次", text: $rounds).keyboardType(.numberPad).disabled(busy)
                    Text("已经开始的轮次也计入总上限。修改目标不会重置轮次。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if conflicted {
                    Section("目标已在其他端更新") {
                        if let latest {
                            Text(latest.objective).textSelection(.enabled)
                            Text("版本 \(latest.revision) · 上限 \(latest.maxGoalRounds) 轮").font(.caption).foregroundStyle(.secondary)
                            if latest.id == base.id, latest.phase != "complete" {
                                Button("保留我的编辑，使用最新版本") { base = latest; operationError = nil }
                                    .disabled(busy)
                            } else { Text("原目标已结束或被替换，请关闭此编辑器查看最新目标。") }
                        } else { Text("原目标已清除，请关闭此编辑器查看最新状态。") }
                    }
                }
                if let operationError { Text(operationError).foregroundStyle(.red).textSelection(.enabled) }
                if busy { ProgressView("正在保存目标") }
            }
            .navigationTitle("编辑目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!valid || conflicted || busy || model.connectionState != .connected)
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }
    private func save() {
        guard valid, !busy, !conflicted, let cap = Int(rounds) else { return }
        busy = true
        operationError = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await model.updateGoal(base, in: sessionID, action: "edit", objective: objective, maxGoalRounds: cap); dismiss() }
            catch { operationError = error.localizedDescription }
        }
    }
}

private struct DSHSubagentsPanel: View {
    let parentID: String
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var watcherToken = UUID()

    var body: some View {
        NavigationStack {
            List {
                if let catalog = model.subagentCatalog(for: parentID) {
                    if catalog.supported == false {
                        Text("这台电脑暂不支持子任务目录。")
                    } else if catalog.entries.isEmpty {
                        Text("暂无子任务").foregroundStyle(.secondary)
                    }
                    if !catalog.parentAvailable, !catalog.entries.isEmpty {
                        Text("父会话当前不在线，仍可查看保存的执行记录。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(catalog.entries) { child in
                        if child.kind == "child" {
                            NavigationLink {
                                DSHSubagentRecord(parentID: parentID, child: child)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(child.label ?? child.id).font(.headline)
                                    Text("\(child.mode == "continuable" ? "可继续会话" : "单次任务") · \(child.activity == "running" ? "运行中" : "未运行")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            VStack(alignment: .leading) {
                                Text(child.id).font(.caption.monospaced())
                                Text("执行记录暂不可用 · \(child.reason ?? "unknown")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if let error = model.subagentCatalogError(for: parentID) {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { model.requestSubagents(for: parentID) }
                } else if model.connectionState != .connected {
                    Text("连接恢复后可读取子任务目录。").foregroundStyle(.secondary)
                } else { ProgressView("正在读取子任务") }
            }
            .navigationTitle("子任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { model.watchSubagents(for: parentID, token: watcherToken) }
            .onDisappear { model.unwatchSubagents(for: parentID, token: watcherToken) }
            .refreshable { model.requestSubagents(for: parentID) }
        }
    }
}

struct DSHSubagentRecord: View {
    let parentID: String
    let child: DSHSubagentCatalog.Entry
    @EnvironmentObject private var model: DSHAppModel
    @State private var showChildren = false
    @State private var showWorkflows = false
    @State private var showExecution = false
    @State private var showReferences = false
    @State private var showHistorySearch = false
    @State private var showSchedules = false
    @State private var focusedHistory: DSHHistoryFocus?
    @State private var historyLoading = false
    @State private var watcherToken = UUID()
    @ObservedObject private var composerDrafts: DSHSubagentComposerDrafts
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var stagingTask: Task<Void, Never>?
    @State private var stagingID = UUID()
    @State private var isStaging = false
    @State private var busy = false
    @State private var operationError: String?
    @State private var operationNotice: String?
    init(parentID: String, child: DSHSubagentCatalog.Entry, composerDrafts: DSHSubagentComposerDrafts = .shared) {
        self.parentID = parentID; self.child = child
        _composerDrafts = ObservedObject(wrappedValue: composerDrafts)
    }
    private var draftAddress: DSHSubagentDraftAddress { .init(machineID: model.machineID, parentID: parentID, childID: child.id) }
    private var draft: String {
        get { composerDrafts.text(for: draftAddress) }
        nonmutating set { composerDrafts.setText(newValue, for: draftAddress) }
    }
    private var delivery: String {
        get { composerDrafts.delivery(for: draftAddress) }
        nonmutating set { composerDrafts.setDelivery(newValue, for: draftAddress) }
    }
    private var images: [DSHStagedAttachment] { composerDrafts.images(for: draftAddress) }

    private func loadChildHistory(beforeSeq: Int64? = nil, atSeq: Int64? = nil) async {
        guard !historyLoading else { return }
        historyLoading = true; operationError = nil
        defer { historyLoading = false }
        do {
            let page = try await model.historyPage(sessionID: child.id, beforeSeq: beforeSeq, atSeq: atSeq, parentID: parentID, mode: currentChild.mode)
            try Task.checkCancellation()
            if atSeq != nil { focusedHistory = page.focus }
        } catch is CancellationError { }
        catch { operationError = error.localizedDescription }
    }

    private var currentChild: DSHSubagentCatalog.Entry {
        model.subagentCatalog(for: parentID)?.entries.first(where: { $0.id == child.id && $0.kind == "child" }) ?? child
    }
    private var canSend: Bool {
        currentChild.mode == "continuable" && model.subagentCatalog(for: parentID)?.parentAvailable == true
            && model.connectionState == .connected && !busy && !isStaging && composerDrafts.isLoaded(draftAddress)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text(currentChild.mode == "continuable" ? "可继续会话 · \(currentChild.activity == "running" ? "运行中" : "未运行")" : "单次任务 · 执行记录只读")
                    .font(.caption).foregroundStyle(.secondary)
                if model.historyCoverage(for: child.id)?.nextBefore != nil || model.historyCoverage(for: child.id) == nil {
                    Button("加载更早的电脑记录") { Task { await loadChildHistory(beforeSeq: model.historyCoverage(for: child.id)?.nextBefore) } }
                        .disabled(historyLoading || model.connectionState != .connected)
                }
                if historyLoading { ProgressView() }
                ForEach(model.transcriptEntries(for: child.id)) { entry in
                    switch entry {
                    case .historyGap(let range):
                        Text("此处还有未加载的历史记录").font(.caption).foregroundStyle(.secondary)
                        Button("加载此处历史") { Task { await loadChildHistory(beforeSeq: range.upper + 1) } }.disabled(historyLoading || model.connectionState != .connected)
                    case .turn(let block):
                        if let duration = block.taskTimeline?.duration() {
                            Text("\(duration.estimated ? "约 " : "")用时 \(duration.seconds) 秒")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(block.messages) { message in
                            if let reasoning = message.reasoning, !reasoning.isEmpty {
                                DisclosureGroup("思考过程") { Text(reasoning).textSelection(.enabled) }
                                    .font(.subheadline)
                            }
                            MessageBubble(sessionID: child.id, message: message)
                        }
                    case .tool(let tool): ToolActivityCard(tool: tool, sessionID: child.id)
                    case .command(let result): CommandResultCard(result: result)
                    case .modelChange(let notice): ModelChangeCard(notice: notice)
                    case .workflow(let run): DSHWorkflowRunCard(sessionID: child.id, run: run)
                    case .execution(let notice): DSHExecutionNoticeCard(sessionID: child.id, notice: notice)
                    }
                }
                ForEach(model.pendingApprovals.filter { $0.sessionId == child.id }) { approval in
                    ApprovalCard(approval: approval, savedDecision: model.approvalDecisionDraft(for: approval)) {
                        try await model.decide(approval, allow: $0)
                    }
                }
                ForEach(model.pendingQuestions.filter { $0.sessionId == child.id }) { request in
                    QuestionCard(request: request, savedDraft: model.questionDraft(for: request),
                        onDraftChange: { model.saveQuestionDraft($0, for: request) },
                        onCancel: { try await model.cancelQuestion(request) }) {
                            try await model.answer(request, answers: $0)
                        }
                }
                if model.usage(for: child.id) != nil { UsageFooter(usage: model.usage(for: child.id)) }
            }
            .padding()
        }
        .navigationTitle(child.label ?? child.id)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Group {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("执行轨迹") { showExecution = true }
                        Button("搜索对话") { showHistorySearch = true }
                        Button("定时提醒") { showSchedules = true }
                        if currentChild.hasChildren == true { Button("下级任务") { showChildren = true } }
                        if !model.workflows(for: child.id).isEmpty { Button("工作流记录") { showWorkflows = true } }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                }
            }
            if currentChild.mode == "continuable", currentChild.activity == "running" {
                ToolbarItem(placement: .primaryAction) {
                    Button("停止", role: .destructive) { performControl(interrupt: true) }
                        .disabled(busy || model.connectionState != .connected)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if currentChild.mode == "continuable" {
                VStack(alignment: .leading, spacing: 8) {
                    if let operationError { Text(operationError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if let operationNotice { Text(operationNotice).font(.caption).foregroundStyle(.secondary) }
                    if model.subagentCatalog(for: parentID)?.parentAvailable == false {
                        Text("父会话离线，恢复后可继续发送。运行中的子任务仍可停止。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !composerDrafts.isLoaded(draftAddress) {
                        HStack {
                            Button("重新读取图片草稿") { loadMediaDraft() }
                            Button("移除图片草稿", role: .destructive) {
                                Task { do { try await composerDrafts.setImages([], for: draftAddress) } catch { operationError = error.localizedDescription } }
                            }
                        }.font(.caption).disabled(busy)
                    }
                    if isStaging { ProgressView("正在准备图片…").font(.caption) }
                    if !images.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(images) { image in
                                    VStack(spacing: 4) {
                                        MessageImageThumbnail(data: image.data, name: image.name)
                                        Button("移除") {
                                            let address = draftAddress
                                            Task { do { try await composerDrafts.removeImage(image.id, for: address) } catch { operationError = error.localizedDescription } }
                                        }.font(.caption).frame(minHeight: 32).disabled(busy || isStaging)
                                    }
                                }
                            }
                        }
                    }
                    TextField("继续子任务", text: Binding(get: { draft }, set: { draft = $0 }), axis: .vertical).lineLimit(1...6)
                        .frame(maxWidth: .infinity, alignment: .leading).disabled(busy)
                    HStack(spacing: 8) {
                        Button { showReferences = true } label: { Image(systemName: "at").font(.system(size: 20)).frame(width: 44, height: 44) }
                            .disabled(busy).accessibilityLabel("插入文件或会话引用")
                        PhotosPicker(selection: $selectedPhotos, maxSelectionCount: max(1, 4 - images.count), matching: .images) {
                            Image(systemName: "photo").font(.system(size: 20)).frame(width: 44, height: 44)
                        }.disabled(busy || isStaging || images.count >= 4 || !composerDrafts.isLoaded(draftAddress)).accessibilityLabel("给子任务添加图片")
                        Spacer(minLength: 8)
                        Menu {
                            Picker("发送方式", selection: Binding(get: { delivery }, set: { delivery = $0 })) {
                                Text("排队").tag("queue")
                                Text("插话").tag("steer")
                            }
                        } label: { Image(systemName: delivery == "steer" ? "bolt" : "clock").font(.system(size: 20)).frame(width: 44, height: 44) }
                            .disabled(busy)
                        Button { performControl(interrupt: false) } label: {
                            if busy { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)).frame(width: 44, height: 44) }
                        }
                        .disabled(!canSend || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty))
                        .accessibilityLabel(delivery == "steer" ? "发送插话" : "发送排队消息")
                    }
                }
                .padding().background(.regularMaterial)
            }
        }
        .sheet(isPresented: $showChildren) { DSHSubagentsPanel(parentID: child.id).environmentObject(model) }
        .sheet(isPresented: $showReferences) { DSHReferencePicker(sessionID: child.id) { draft = dshAppendReference($0, to: draft) } }
        .sheet(isPresented: $showExecution) { DSHExecutionPanel(sessionID: child.id, parentID: parentID, mode: currentChild.mode).environmentObject(model) }
        .sheet(isPresented: $showHistorySearch) {
            DSHHistorySearchPanel(sessionID: child.id, parentID: parentID, mode: currentChild.mode) { hit in
                guard let seq = hit.nativeSequence else { return }
                Task { await loadChildHistory(atSeq: seq) }
            }.environmentObject(model)
        }
        .sheet(item: $focusedHistory) { DSHHistoryFocusView(sessionID: child.id, focus: $0).environmentObject(model) }
        .sheet(isPresented: $showSchedules) { DSHSchedulePanel(sessionID: child.id, parentID: parentID, mode: currentChild.mode).environmentObject(model) }
        .sheet(isPresented: $showWorkflows) {
            DSHWorkflowsPanel(sessionID: child.id, parentID: parentID, child: currentChild).environmentObject(model)
        }
        .task {
            loadMediaDraft()
            model.watchSubagents(for: parentID, token: watcherToken)
            model.openSubagent(child, parentID: parentID)
        }
        .onChange(of: selectedPhotos) { _, value in stagePhotos(value) }
        .onDisappear { stagingTask?.cancel(); model.unwatchSubagents(for: parentID, token: watcherToken) }
        .onChange(of: model.connectionState) { _, value in
            if value == .connected { model.openSubagent(child, parentID: parentID) }
        }
        .refreshable { model.openSubagent(child, parentID: parentID) }
    }

    private func performControl(interrupt: Bool) {
        guard !busy else { return }
        busy = true
        operationError = nil
        operationNotice = nil
        let submitted = draft, submittedImages = images, submittedDelivery = delivery, address = draftAddress
        let generation = model.currentMachineGeneration
        Task { @MainActor in
            defer { busy = false }
            do {
                if !interrupt { try await composerDrafts.persist(address) }
                guard model.machineID == address.machineID, model.currentMachineGeneration == generation else { throw CancellationError() }
                try await model.controlSubagent(childID: child.id, parentID: parentID,
                                                text: interrupt ? nil : submitted, delivery: submittedDelivery,
                                                images: interrupt ? [] : submittedImages.map(\.subagentImagePart))
                operationNotice = interrupt ? "停止信号已接收，等待任务状态更新。" : "Harness 已接收消息。"
                if !interrupt {
                    do { try await composerDrafts.consume(text: submitted, delivery: submittedDelivery, images: submittedImages, address: address) }
                    catch { operationError = "Harness 已接收；本机图片草稿清理失败：\(error.localizedDescription)" }
                }
            } catch { operationError = error.localizedDescription }
        }
    }

    private func loadMediaDraft() {
        let address = draftAddress
        Task { do { try await composerDrafts.load(address) } catch { operationError = error.localizedDescription } }
    }
    private func stagePhotos(_ selected: [PhotosPickerItem]) {
        guard !selected.isEmpty else { return }
        stagingTask?.cancel()
        let address = draftAddress, identity = UUID()
        stagingID = identity
        isStaging = true; operationError = nil
        stagingTask = Task { @MainActor in
            defer { if stagingID == identity { isStaging = false; selectedPhotos = [] } }
            do {
                var staged = [DSHStagedAttachment]()
                guard selected.count <= max(0, 4 - images.count) else { throw DSHSubagentDraftError(message: "子任务最多附带 4 张图片，请减少选择数量或先移除已有图片。") }
                for item in selected {
                    guard let data = try await item.loadTransferable(type: Data.self), data.count <= 32 * 1_024 * 1_024 else {
                        throw DSHSubagentDraftError(message: "图片无法读取或原图超过 32 MiB，请选择较小的图片。")
                    }
                    let optimized = await optimizedPhotoDataOffMain(data)
                    try Task.checkCancellation()
                    guard optimized.starts(with: [0xff, 0xd8]) else { throw DSHSubagentDraftError(message: "此图片无法转换为可发送的格式，请换一张图片。") }
                    staged.append(.init(name: "photo.jpg", data: optimized, isImage: true))
                }
                try Task.checkCancellation()
                guard address == draftAddress else { throw CancellationError() }
                guard !staged.isEmpty else { throw DSHSubagentDraftError(message: "子任务最多附带 4 张图片，请先移除已有图片。") }
                try await composerDrafts.setImages(composerDrafts.images(for: address) + staged, for: address)
            } catch is CancellationError { }
            catch { operationError = error.localizedDescription }
        }
    }
}

struct QueuedPromptsSheet: View {
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    @State private var editingItem: DSHAppModel.DSHQueuedPrompt?
    @State private var editingText = ""
    @State private var serverEditingItem: DSHServerQueue.Item?
    @State private var busyItemID: String?
    @State private var mutationError: String?

    var body: some View {
        NavigationStack {
            List {
                let queued = model.queuedPrompts(for: sessionID)
                let server = model.serverQueue(for: sessionID)
                if let mutationError { Text(mutationError).foregroundStyle(.red).font(.caption) }
                if let server, !server.items.isEmpty {
                    Section("Harness 已接收") {
                        if !server.available || model.connectionState != .connected {
                            Text("队列状态暂未同步，连接恢复前不能修改。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(server.items) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.placement == "steering" ? "插话" : item.placement == "context" ? "上下文" : "排队")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                if !item.text.isEmpty { Text(item.text).textSelection(.enabled) }
                                if let attachments = item.attachments, !attachments.isEmpty {
                                    MessageAttachmentsView(sessionID: sessionID, attachments: attachments)
                                }
                                if !item.isTextOnly {
                                    Text("包含附件或结构化内容").font(.caption).foregroundStyle(.secondary)
                                    DisclosureGroup("查看原始内容") {
                                        Text(rawQueueContent(item)).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                }
                                if busyItemID == item.id { ProgressView() }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if item.placement != "context" {
                                    if item.placement == "queued" {
                                        Button("转为插话") { mutateServer(item, action: "steer") }.tint(.accentColor)
                                            .disabled(!server.available || model.connectionState != .connected || busyItemID != nil)
                                    }
                                    if item.isTextOnly {
                                        Button("编辑") { serverEditingItem = item; editingText = item.text }
                                            .disabled(!server.available || model.connectionState != .connected || busyItemID != nil)
                                    }
                                    Button("删除", role: .destructive) { mutateServer(item, action: "remove") }
                                        .disabled(!server.available || model.connectionState != .connected || busyItemID != nil)
                                }
                            }
                        }
                    }
                }
                if queued.isEmpty {
                    if server?.items.isEmpty != false { Text("暂无排队消息")
                        .foregroundStyle(.secondary)
                    }
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
                        Text("本机暂存的消息尚未发送，可编辑、取消或立即发送；Harness 已接收的消息使用上方真实队列，可按项目编辑、删除或转为插话。")
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
            .alert("编辑 Harness 队列", isPresented: Binding(
                get: { serverEditingItem != nil }, set: { if !$0 { serverEditingItem = nil } }
            )) {
                TextField("消息内容", text: $editingText, axis: .vertical)
                Button("取消", role: .cancel) { serverEditingItem = nil }
                Button("保存") {
                    if let item = serverEditingItem { mutateServer(item, action: "edit", text: editingText) }
                    serverEditingItem = nil
                }
            }
        }
    }

    private func sendNow(_ item: DSHAppModel.DSHQueuedPrompt) {
        model.sendQueuedPrompt(id: item.id, sessionID: sessionID)
    }
    private func mutateServer(_ item: DSHServerQueue.Item, action: String, text: String? = nil) {
        guard busyItemID == nil else { return }
        busyItemID = item.id
        mutationError = nil
        Task { @MainActor in
            defer { busyItemID = nil }
            do { try await model.updateServerQueue(item, in: sessionID, action: action, text: text) }
            catch {
                mutationError = error.localizedDescription
                if action == "edit" { serverEditingItem = item }
            }
        }
    }
    private func rawQueueContent(_ item: DSHServerQueue.Item) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(item.message.content) else { return "" }
        return String(decoding: data, as: UTF8.self)
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
    /// Present only for the current transient assistant delta.  The
    /// measurement happens before the outer min-height is applied, so it
    /// remains the intrinsic Markdown layout rather than the reserved shell.
    let streamingMeasurementID: String?
    let streamingMinimumHeight: CGFloat?
    @State private var selectedFile: DSHFileReference?
    @State private var showActions = false
    @State private var showFeedback = false
    @State private var feedbackRating = "positive"
    @State private var referencedSessionID: String?
    @State private var didCopy = false

    init(sessionID: String, message: DSHChatMessage, onBranch: (() -> Void)? = nil,
         streamingMeasurementID: String? = nil, streamingMinimumHeight: CGFloat? = nil) {
        self.sessionID = sessionID
        self.message = message
        self.onBranch = onBranch
        self.streamingMeasurementID = streamingMeasurementID
        self.streamingMinimumHeight = streamingMinimumHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if model.interruptedMessage(message, in: sessionID) {
                Label("以下为中断前已保存的回答", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Media lives outside the tinted bubble so photos are never
            // squeezed into (or masked by) its rounded shape.
            if !message.attachments.isEmpty {
                HStack {
                    if message.role == .user { Spacer(minLength: 36) }
                    MessageAttachmentsView(sessionID: sessionID, attachments: message.attachments,
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

                    if message.role == .assistant && streamingMeasurementID == nil {
                        ForEach(["positive", "negative"], id: \.self) { rating in
                            Button {
                                feedbackRating = rating; showFeedback = true
                            } label: {
                                let selected = model.feedback(for: message.id, in: sessionID)?.rating == rating
                                Image(systemName: (rating == "positive" ? "hand.thumbsup" : "hand.thumbsdown") + (selected ? ".fill" : ""))
                                    .font(.system(size: 17)).frame(width: 28, height: 28)
                            }.accessibilityLabel(rating == "positive" ? "评价有帮助" : "评价需要改进")
                        }
                    }

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
        .background {
            if let streamingMeasurementID {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: DSHStreamMessageMeasurementKey.self,
                        value: DSHStreamMessageMeasurement(streamID: streamingMeasurementID,
                                                           size: proxy.size)
                    )
                }
            }
        }
        .frame(minHeight: streamingMinimumHeight ?? 0, alignment: .top)
        .environment(\.openURL, OpenURLAction { url in
            if let id = DSHSessionReference.sessionID(from: url) {
                referencedSessionID = id
                return .handled
            }
            if let reference = DSHFileReference(url: url, sessionID: sessionID) {
                selectedFile = reference
                return .handled
            }
            return .systemAction
        })
        .sheet(item: $selectedFile) { DSHRemoteFilePreview(reference: $0) }
        .sheet(isPresented: $showFeedback) { DSHFeedbackEditor(sessionID: sessionID, messageID: message.id, initialRating: feedbackRating) }
        .navigationDestination(isPresented: Binding(get: { referencedSessionID != nil }, set: { if !$0 { referencedSessionID = nil } })) {
            if let referencedSessionID { ConversationView(sessionID: referencedSessionID) }
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
struct MessageAttachmentsView: View {
    let sessionID: String
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
                            MessageAttachmentPreview(sessionID: sessionID, attachment: attachment)
                        }
                    }
                    // Short rows hug the leading edge of a horizontal
                    // scroller; stretch to the viewport so trailing
                    // alignment (user uploads) actually holds.
                    .frame(maxWidth: .infinity, alignment: alignTrailing ? .trailing : .leading)
                }
            }
            ForEach(files) { attachment in
                MessageAttachmentPreview(sessionID: sessionID, attachment: attachment)
            }
        }
        .frame(maxWidth: 300, alignment: alignTrailing ? .trailing : .leading)
    }
}

private struct MessageAttachmentPreview: View {
    @EnvironmentObject private var model: DSHAppModel
    let sessionID: String
    let attachment: DSHMessageAttachment
    @State private var data: Data?
    @State private var selectedFile: DSHFileReference?

    var body: some View {
        Group {
            if model.connectionState != .connected, let data, attachment.isImage, UIImage(data: data) != nil {
                MessageImageThumbnail(data: data, name: attachment.name + "（缓存预览）")
            } else if let reference = attachment.fileReference(sessionID: sessionID) {
                Button { selectedFile = reference } label: {
                    if let data, attachment.isImage, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else { attachmentLabel }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开 \(attachment.name)")
            } else if let data, attachment.isImage, UIImage(data: data) != nil {
                MessageImageThumbnail(data: data, name: attachment.name)
            } else { attachmentLabel }
        }
        .task(id: attachment) {
            data = model.attachmentData(for: attachment) ?? attachment.thumbnailData
        }
        .sheet(item: $selectedFile) { DSHRemoteFilePreview(reference: $0) }
    }

    private var attachmentLabel: some View {
        Group {
            if attachment.isImage {
                RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.08))
                    .frame(width: 96, height: 96)
                    .overlay { Image(systemName: "photo").font(.title3).foregroundStyle(Color.secondary) }
                    .accessibilityLabel(attachment.name)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "paperclip").font(.caption.weight(.semibold))
                    Text(attachment.name).font(.caption).lineLimit(2).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if attachment.hostPath != nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.secondary) }
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .frame(minHeight: 44)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
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
/// Holds parsed blocks for one visible message.  SwiftUI reconstructs value
/// views whenever any live event arrives; parsing every old message on every
/// 50 ms stream batch made a long transcript increasingly expensive.  A state
/// object is retained by the message's stable identity, so only the changing
/// message is parsed again.  Markdown is deliberately reparsed in full for
/// that one message: syntax can become a heading, list or fence without a
/// newline (`#` + ` title`, for example), so speculative incremental parsing
/// would eventually render a different document from the source.
@MainActor
final class DSHMarkdownBlockRenderer: ObservableObject {
    @Published private(set) var blocks: [DSHMarkdownBlock]
    private var source: String
    /// Observable in tests only; it also documents that unchanged SwiftUI
    /// body passes cannot trigger another parse.
    private(set) var parseCount = 0

    init(text: String) {
        source = text
        blocks = DSHMarkdown.blocks(from: text)
        parseCount = 1
    }

    func update(text: String) {
        guard text != source else { return }
        source = text
        blocks = DSHMarkdown.blocks(from: text)
        parseCount += 1
    }
}

/// `AttributedString(markdown:)` interprets inline syntax only, so headings,
/// fenced code, lists and tables reached the reader as their literal markers —
/// `#`, ``` ``` ``` and `|` included. Block structure is recognised first
/// (`DSHMarkdown`), then each block is styled; inline markup inside a block is
/// still left to `AttributedString`.
struct MarkdownBlockText: View {
    let text: String
    @StateObject private var renderer: DSHMarkdownBlockRenderer

    init(text: String) {
        self.text = text
        _renderer = StateObject(wrappedValue: DSHMarkdownBlockRenderer(text: text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(renderer.blocks) { block in
                MarkdownBlockView(block: block)
            }
        }
        .onChange(of: text) { _, updatedText in
            renderer.update(text: updatedText)
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
    let isTaskRunning: Bool
    let streamingMessage: DSHActiveStreamingMessage?
    let streamingMinimumHeight: CGFloat?
    let onBranch: () -> Void

    @State private var isExpanded = false

    private var timeline: DSHTaskTimeline? { block.taskTimeline }
    private var text: String { timeline?.reasoning ?? "" }
    private var tools: [DSHToolActivity] { timeline?.tools ?? [] }
    private var answerCount: Int { timeline?.messages.filter { !$0.markdown.isEmpty }.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if timeline != nil {
                timelineRow
                // Same width as the reply text: no full-bleed. The old
                // -16 bleed drew the rule past the text on both sides.
                Divider()
                    .padding(.top, 8)
            }
            ForEach(block.visibleMessages) { message in
                MessageBubble(sessionID: sessionID,
                              message: message,
                              onBranch: onBranch,
                              streamingMeasurementID: message.id == streamingMessage?.renderedMessageID
                                ? streamingMessage?.streamID : nil,
                              streamingMinimumHeight: message.id == streamingMessage?.renderedMessageID
                                ? streamingMinimumHeight : nil)
                    .padding(.top, 12)
            }
        }
    }

    private var isExpandable: Bool {
        !text.isEmpty || !tools.isEmpty
    }

    /// Reference layout: timing text with the chevron tucked right behind
    /// it (not pinned to the trailing edge), then a full-bleed divider.
    @ViewBuilder
    private var timelineRow: some View {
        if isExpandable {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() }
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
                    ToolActivityCard(tool: tool, sessionID: sessionID, isLive: isTaskRunning)
                }
            }
            .padding(.bottom, 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var timelineLabel: some View {
        HStack(spacing: 6) {
            Group {
                if isTaskRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(timelineTitle(now: context.date))
                    }
                } else {
                    Text(timelineTitle(now: nil))
                }
            }
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

    private func timelineTitle(now: Date?) -> String {
        guard let duration = timeline?.duration(now: now) else {
            return DSHLocalization.string("Thinking")
        }
        return (duration.estimated ? "≈ " : "") + turnDurationText(duration.seconds)
    }

    private func turnDurationText(_ seconds: Int) -> String {
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

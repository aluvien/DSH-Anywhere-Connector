import SwiftUI
import UIKit

/// Keep secondary screens unchanged; scrolling home/conversation headers use
/// a lighter native blur, without an extra tinted page-color wash.
struct DSHHeaderBackdrop: View {
    var frosted = false
    var contentUnderneath = true
    var body: some View {
        Group {
            if frosted {
                if contentUnderneath {
                    DSHHeaderBlur()
                } else {
                    Color(.systemBackground)
                }
            } else {
                Color(.systemBackground).opacity(0.5)
            }
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}

/// Interpolate the native effect itself: lowering the opacity of a material
/// mixes sharp original text back in and looks like a gray transparent sheet.
private struct DSHHeaderBlur: UIViewRepresentable {
    func makeUIView(context: Context) -> BlurView { BlurView() }
    func updateUIView(_ view: BlurView, context: Context) {}
    static func dismantleUIView(_ view: BlurView, coordinator: ()) { view.stop() }

    final class BlurView: UIVisualEffectView {
        private var animator: UIViewPropertyAnimator?
        init() {
            super.init(effect: nil)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stop() }
            setNeedsDisplay()
        }
        override func draw(_ rect: CGRect) {
            super.draw(rect)
            guard animator == nil, window != nil else { return }
            effect = nil
            let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [weak self] in
                self?.effect = UIBlurEffect(style: .regular)
            }
            self.animator = animator
            animator.fractionComplete = 0.08
        }
        func stop() {
            animator?.stopAnimation(true)
            animator = nil
            effect = nil
        }
    }
}

/// Observes only its enclosing scroll view, including programmatic scrolling.
/// Publishing on the next run-loop avoids state changes during UIKit layout.
struct DSHHeaderScrollProbe: UIViewRepresentable {
    @Binding var overlaps: Bool
    var topSpacing: CGFloat = 12

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.topSpacing = topSpacing
        view.publish = { overlaps = $0 }
        view.attach()
    }

    final class Probe: UIView {
        var publish: ((Bool) -> Void)?
        var topSpacing: CGFloat = 12
        private weak var scroll: UIScrollView?
        private var observations: [NSKeyValueObservation] = []
        private var lastValue: Bool?
        override func didMoveToSuperview() { super.didMoveToSuperview(); attach() }
        override func didMoveToWindow() { super.didMoveToWindow(); attach() }
        func attach() {
            isUserInteractionEnabled = false
            var ancestor = superview
            while let view = ancestor {
                if let found = view as? UIScrollView {
                    if scroll !== found {
                        scroll = found
                        observations = [
                            found.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in self?.refresh() },
                            found.observe(\.adjustedContentInset, options: [.new]) { [weak self] _, _ in self?.refresh() },
                            found.observe(\.contentSize, options: [.new]) { [weak self] _, _ in self?.refresh() }
                        ]
                    }
                    refresh()
                    return
                }
                ancestor = view.superview
            }
        }
        private func refresh() {
            guard let scroll else { return }
            let value = scroll.contentSize.height > 0
                && scroll.contentOffset.y + scroll.adjustedContentInset.top > topSpacing
            guard lastValue != value else { return }
            lastValue = value
            DispatchQueue.main.async { [weak self] in
                guard let self, let latest = self.lastValue else { return }
                self.publish?(latest)
            }
        }
    }
}

/// Floating glass chrome (Liquid Glass, iOS 26+). Below 26 the same call
/// site renders the legacy solid card, so one call site serves both.
/// Glass is reserved for floating controls (composer card, jump key, header
/// capsule); transcript content stays solid for readability.
extension View {
    @ViewBuilder
    func dshFloatingChrome<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(Color(.systemBackground), in: shape)
                .overlay {
                    shape.stroke(Color.primary.opacity(0.11), lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }
}

/// Vector glyphs reconstructed from the Remote iOS reference captures.
///
/// Every glyph renders on a transparent surface. Containers such as the pale
/// circles in the attachment menu are deliberately owned by the caller, so
/// the same artwork can be reused in a toolbar, menu, or compact composer.
struct DSHRemoteFolderGlyph: View {
    let expanded: Bool

    var body: some View {
        Group {
            if expanded {
                DSHRemoteOpenFolderShape()
                    .stroke(style: remoteStroke(width: 2.25))
            } else {
                DSHRemoteClosedFolderShape()
                    .stroke(style: remoteStroke(width: 2.25))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// One visual height shared by every composer control glyph (plus, mic,
/// permission, context ring, reasoning meter). Fixed heights — not font
/// sizes — so their top/bottom edges line up: two SF Symbols at the same
/// font size never match because each glyph carries its own bounding box.
let DSHComposerGlyphHeight: CGFloat = 19

struct DSHRemotePlusGlyph: View {
    var body: some View {
        Image(systemName: "plus")
            .resizable()
            .scaledToFit()
            .fontWeight(.regular)
            .frame(height: DSHComposerGlyphHeight)
    }
}

struct DSHRemoteComposeGlyph: View {
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: "square.and.pencil")
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size, weight: .regular))
    }
}

struct DSHRemoteMicrophoneGlyph: View {
    var body: some View {
        Image(systemName: "mic")
            .resizable()
            .scaledToFit()
            .fontWeight(.regular)
            .frame(height: DSHComposerGlyphHeight)
    }
}

struct DSHRemotePermissionGlyph: View {
    enum Style {
        case hand
        case terminalShield
        case warningShield
        case settings
    }

    let style: Style
    /// Visual height shared with every other composer control (see
    /// `DSHComposerGlyphHeight`). Kept as a parameter so previews can probe
    /// sizes; production call sites use the default.
    var size: CGFloat = 19

    @ViewBuilder
    var body: some View {
        switch style {
        case .hand:
            Image(systemName: "hand.raised")
                .resizable()
                .scaledToFit()
                .fontWeight(.regular)
                .frame(height: size)
        case .terminalShield:
            ZStack {
                Image(systemName: "shield")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.regular)
                    .frame(height: size)
                DSHRemoteTerminalMarkShape()
                    .stroke(style: remoteStroke(width: 1.35))
                    .frame(width: size * 0.43, height: size * 0.28)
                    .offset(y: -size * 0.02)
            }
        case .warningShield:
            Image(systemName: "exclamationmark.shield")
                .resizable()
                .scaledToFit()
                .fontWeight(.regular)
                .frame(height: size)
        case .settings:
            Image(systemName: "gearshape")
                .resizable()
                .scaledToFit()
                .fontWeight(.regular)
                .frame(height: size)
        }
    }
}

extension DSHRemotePermissionGlyph.Style {
    /// Maps the persisted Harness sandbox value to the glyph used in both the
    /// compact composer button and its permission picker rows.
    static func forPermissionMode(_ mode: String) -> Self {
        switch mode {
        case "read-only": return .hand
        case "danger-full-access": return .warningShield
        default: return .terminalShield
        }
    }

    var composerColor: Color {
        switch self {
        case .warningShield: return .orange
        default: return .primary
        }
    }
}

struct DSHRemoteActionGlyph: View {
    enum Kind {
        case plan
        case goal
        case file
        case camera
        case photos
    }

    let kind: Kind

    @ViewBuilder
    var body: some View {
        switch kind {
        case .plan:
            Image(systemName: "list.bullet")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 22, weight: .regular))
        case .goal:
            Image(systemName: "target")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 22, weight: .regular))
        case .file:
            Image(systemName: "paperclip")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 22, weight: .regular))
        case .camera:
            Image(systemName: "camera")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 22, weight: .regular))
        case .photos:
            Image(systemName: "photo.on.rectangle.angled")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 22, weight: .regular))
        }
    }
}

/// Context usage ring from the reference editor. The track is neutral gray;
/// the live used fraction is the only black segment. The gap position stays
/// fixed at the upper-left just like the captured glyph.
struct DSHRemoteContextGlyph: View {
    var progress: Double

    private var clamped: Double { min(0.98, max(0, progress)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.17), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.025, clamped))
                .stroke(
                    Color.primary,
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                .rotationEffect(.degrees(-100))
        }
        .frame(width: DSHComposerGlyphHeight, height: DSHComposerGlyphHeight)
        .animation(.easeInOut(duration: 0.22), value: clamped)
    }
}

/// Animated reasoning meter. `intensity` is continuous (0...1), so switching
/// between model effort presets moves both the blue arc and needle instead of
/// swapping unrelated static images.
///
/// These values are intentionally internal so the visual invariant can be
/// unit-tested without rendering SwiftUI: the needle's angle is always the
/// blue arc's terminal angle.
enum DSHReasoningGlyphMetrics {
    static let startAngle: Double = 135
    static let sweepAngle: Double = 195

    static func angle(for intensity: Double) -> Double {
        startAngle + sweepAngle * min(1, max(0, intensity))
    }

    static func arcEnd(for intensity: Double) -> Double {
        angle(for: intensity) / 360
    }
}

struct DSHRemoteReasoningGlyph: View {
    var intensity: Double

    private var clamped: Double { min(1, max(0, intensity)) }
    private var arcEnd: Double { DSHReasoningGlyphMetrics.arcEnd(for: clamped) }
    private var needleAngle: Double { DSHReasoningGlyphMetrics.angle(for: clamped) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray4), lineWidth: 1.9)

            Circle()
                .trim(from: 0.375, to: arcEnd)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )

            Circle()
                .stroke(Color.primary, lineWidth: 1.4)
                .frame(width: 5.5, height: 5.5)

            Capsule()
                .fill(Color.primary)
                .frame(width: 7.5, height: 1.8)
                .offset(x: 3.2)
                .rotationEffect(.degrees(needleAngle))
        }
        .frame(width: DSHComposerGlyphHeight, height: DSHComposerGlyphHeight)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: clamped)
    }
}

/// A stepped intelligence rail matching the expanded model picker.  The
/// slider is intentionally discrete: dragging snaps to the nearest catalog
/// effort while the fill, knob and glyph animate as one continuous state.
///
/// Tick labels share the exact rail geometry below, so the knob pointer, the
/// dot and the label for one index are all centered on the same x. The header
/// above the rail live-syncs to the draft via `onChanged`; the caller commits
/// once on dismiss.
struct DSHRemoteReasoningSlider: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var feedback = UISelectionFeedbackGenerator()

    let count: Int
    let selectedIndex: Int
    let onChanged: (Int) -> Void
    let labels: [String]

    init(count: Int, selectedIndex: Int, labels: [String] = [], onChanged: @escaping (Int) -> Void) {
        self.count = max(1, count)
        self.selectedIndex = min(max(0, selectedIndex), max(0, count - 1))
        self.labels = Array(labels.prefix(max(1, count)))
        self.onChanged = onChanged
    }

    private var lastIndex: Int { count - 1 }
    private var showsLabels: Bool { labels.count == count && count > 1 }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                let metrics = DSHReasoningRailMetrics(width: proxy.size.width)
                let knobX = metrics.x(for: lastIndex == 0 ? 0 : CGFloat(selectedIndex) / CGFloat(lastIndex))
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(Color(.tertiarySystemFill))
                    // Fill and knob have identical heights and end caps. At the
                    // minimum the fill sits exactly behind the knob, never beside it.
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: knobX + metrics.knobDiameter / 2 - metrics.outerInset,
                               height: metrics.knobDiameter)
                        .offset(x: metrics.outerInset, y: metrics.outerInset)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: selectedIndex)
                    ForEach(0..<count, id: \.self) { index in
                        Circle()
                            .fill(index <= selectedIndex ? Color.white.opacity(0.4) : Color(.systemGray3))
                            .frame(width: 6, height: 6)
                            .position(x: metrics.x(for: lastIndex == 0 ? 0 : CGFloat(index) / CGFloat(lastIndex)),
                                      y: metrics.height / 2)
                    }
                    Circle()
                        .fill(.white)
                        .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 2) }
                        .frame(width: metrics.knobDiameter, height: metrics.knobDiameter)
                        .position(x: knobX, y: metrics.height / 2)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: selectedIndex)
                }
                .frame(width: proxy.size.width, height: metrics.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let next = metrics.index(for: value.location.x, lastIndex: lastIndex)
                        if next != selectedIndex { feedback.selectionChanged(); feedback.prepare(); onChanged(next) }
                    })
            }
            .frame(height: DSHReasoningRailMetrics.railHeight)

            if showsLabels {
                GeometryReader { proxy in
                    let metrics = DSHReasoningRailMetrics(width: proxy.size.width)
                    ForEach(0..<count, id: \.self) { index in
                        Text(labels[index])
                            .font(.system(size: 11, weight: index == selectedIndex ? .semibold : .regular))
                            .foregroundStyle(index == selectedIndex ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: metrics.labelWidth(for: count))
                            .position(x: metrics.x(for: CGFloat(index) / CGFloat(lastIndex)), y: 9)
                    }
                }
                .frame(height: 18)
            }
        }
        // A parent glass/control animation must not animate the rail's coordinate space.
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("思考深度")
        .accessibilityValue(labels.indices.contains(selectedIndex) ? labels[selectedIndex] : "\(selectedIndex + 1) / \(count)")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 1 : -1
            let next = min(max(0, selectedIndex + delta), lastIndex)
            if next != selectedIndex { feedback.selectionChanged(); feedback.prepare(); onChanged(next) }
        }
    }
}

/// All geometry, including hit testing, uses rail-local coordinates.
struct DSHReasoningRailMetrics {
    static let railHeight: CGFloat = 44
    let outerInset: CGFloat = 5
    let knobDiameter: CGFloat = 34
    let railWidth: CGFloat
    var height: CGFloat { Self.railHeight }
    var knobTravel: CGFloat { max(0, railWidth - knobDiameter) }

    init(width: CGFloat) {
        railWidth = max(knobDiameter, width - outerInset * 2)
    }

    func x(for fraction: CGFloat) -> CGFloat {
        outerInset + knobDiameter / 2 + knobTravel * min(max(0, fraction), 1)
    }

    func index(for locationX: CGFloat, lastIndex: Int) -> Int {
        guard lastIndex > 0, knobTravel > 0 else { return 0 }
        let position = min(max(locationX - x(for: 0), 0), knobTravel)
        return Int(round(position / knobTravel * CGFloat(lastIndex)))
    }

    func labelWidth(for count: Int) -> CGFloat {
        min(knobDiameter + outerInset * 2, knobTravel / CGFloat(max(1, count - 1)))
    }
}

struct DSHComposerPermissionPicker: View {
    @Binding var mode: String
    var compact = true
    @State private var isPresented = false


    static func iconStyle(for mode: String) -> DSHRemotePermissionGlyph.Style {
        .forPermissionMode(mode)
    }

    var body: some View {
        Button { isPresented = true } label: {
            if compact {
                let style = Self.iconStyle(for: mode)
                DSHRemotePermissionGlyph(style: style)
                    .frame(width: 34, height: 34)
                    .foregroundStyle(style.composerColor)
            } else {
                DSHRemotePermissionGlyph(
                    style: Self.iconStyle(for: mode)
                )
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("应如何批准 DSH 操作？")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 5)

                ForEach(permissionModes, id: \.mode) { item in
                    permissionRow(item)
                }
            }
            .padding(10)
            .frame(width: 340)
            .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("Permission: \(permissionLabel(mode))")
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
    /// but are intentionally not offered as separate modes here. Row icons
    /// match the composer button glyph.
    private var permissionModes: [(mode: String, title: String, icon: DSHRemotePermissionGlyph.Style)] {
        // Titles are localized here rather than left to `Label`, which only
        // localizes a literal and takes this value as a plain String.
        [
            ("read-only", "仅可查看", .hand),
            ("workspace-write", DSHLocalization.string("Workspace write"), .terminalShield),
            ("danger-full-access", "完全权限", .warningShield)
        ]
    }

    private func permissionRow(
        _ item: (mode: String, title: String, icon: DSHRemotePermissionGlyph.Style)
    ) -> some View {
        Button {
            mode = item.mode
            isPresented = false
        } label: {
            HStack(alignment: .top, spacing: 12) {
                DSHRemotePermissionGlyph(style: item.icon)
                    .foregroundStyle(item.mode == "danger-full-access" ? .red : .primary)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 17, weight: .medium))
                    Text(permissionDetail(item.mode))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if mode == item.mode {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func permissionDetail(_ mode: String) -> String {
        switch mode {
        case "read-only": return "只读取文件；任何修改前都会询问"
        case "danger-full-access": return "完全访问计算机（风险较高）"
        default: return "可编辑当前工作区内的文件"
        }
    }
}

/// One anchored picker for both composers. Model choices stay inside this
/// surface: presenting a native Menu from a glass popover causes two competing
/// presentation/morph animations on iOS 26.
struct DSHModelConfigurationPicker: View {
    let catalog: DSHModelCatalog?
    @Binding var selection: DSHModelSelection
    let fallbackName: String
    var fallbackEfforts: [DSHModelReasoningEffort] = []
    var compact = true
    var onCommit: (DSHModelSelection) -> Void = { _ in }
    /// Lets a hosting full-screen surface suspend broad navigation gestures
    /// while this picker owns a horizontal reasoning-slider interaction.
    var onPresentationChanged: (Bool) -> Void = { _ in }
    @State private var isPresented = false
    @State private var draft: DSHModelSelection?
    @State private var openedSelection: DSHModelSelection?
    @State private var showsModels = false

    private var displayedSelection: DSHModelSelection { draft ?? selection }
    private var displayedEfforts: [DSHModelReasoningEffort] {
        dshModelEfforts(catalog: catalog, selection: displayedSelection, fallback: fallbackEfforts)
    }
    private var name: String {
        dshCatalogModel(catalog: catalog, selection: displayedSelection)?.name ?? fallbackName
    }

    var body: some View {
        Button {
            openedSelection = displayedSelection
            draft = displayedSelection
            showsModels = false
            isPresented = true
        } label: {
            if compact {
                Group {
                    if displayedEfforts.isEmpty {
                        Image(systemName: "cpu")
                    } else {
                        DSHRemoteReasoningGlyph(intensity: dshReasoningIntensity(displayedEfforts,
                            selectedEffortID: dshModelEffortID(catalog: catalog, selection: displayedSelection,
                                                            efforts: displayedEfforts)))
                    }
                }
                .frame(width: 34, height: 34)
            } else {
                HStack(spacing: 3) {
                    Text(name).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.system(size: 14))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel("模型与智能：\(name)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DSHModelConfigurationPanel(
                catalog: catalog,
                selection: Binding(get: { displayedSelection }, set: { draft = $0 }),
                fallbackName: fallbackName, fallbackEfforts: fallbackEfforts,
                showsModels: $showsModels
            )
            .presentationCompactAdaptation(.popover)
            .presentationBackground(.regularMaterial)
        }
        .onChange(of: isPresented) { _, presented in
            onPresentationChanged(presented)
            guard !presented, let draft, draft != openedSelection else { return }
            selection = draft
            onCommit(draft)
        }
        .onChange(of: selection) { _, value in
            if !isPresented { draft = value }
        }
    }
}

/// Constant outer bounds keep model/effort changes from resizing the system
/// popover while it is onscreen. Only the inner page changes.
struct DSHModelConfigurationPanel: View {
    let catalog: DSHModelCatalog?
    @Binding var selection: DSHModelSelection
    let fallbackName: String
    var fallbackEfforts: [DSHModelReasoningEffort] = []
    @Binding var showsModels: Bool

    private var item: DSHModelCatalogModel? { dshCatalogModel(catalog: catalog, selection: selection) }
    private var efforts: [DSHModelReasoningEffort] {
        dshModelEfforts(catalog: catalog, selection: selection, fallback: fallbackEfforts)
    }
    private var selectedIndex: Int {
        dshNearestReasoningEffortIndex(efforts, to: dshModelEffortID(catalog: catalog,
                                                                  selection: selection, efforts: efforts))
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsModels {
                HStack {
                    Button { showsModels = false } label: {
                        Label("返回", systemImage: "chevron.left").font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("模型").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Color.clear.frame(width: 48, height: 1)
                }
                .frame(height: 40)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(catalog?.groups ?? []) { group in
                            Text(group.name)
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.top, 8)
                            ForEach(group.models) { model in
                                Button {
                                    if group.id != selection.provider || model.id != selection.model {
                                        selection = DSHModelSelection(provider: group.id, model: model.id,
                                            reasoningEffort: model.reasoning?.defaultEffort ?? model.reasoning?.efforts.first?.id)
                                    }
                                    showsModels = false
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(model.name)
                                            .font(.system(size: 15))
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if group.id == selection.provider && model.id == selection.model {
                                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("model-choice-\(group.id)-\(model.id)")
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                Button { showsModels = true } label: {
                    HStack(spacing: 8) {
                        Text("模型").font(.system(size: 17)).fixedSize()
                        Spacer(minLength: 4)
                        Text(item?.name ?? fallbackName)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("model-list-toggle")
                .disabled(catalog?.groups.isEmpty ?? true)
                Divider().padding(.top, 8).padding(.bottom, 18)
                HStack {
                    Text("智能").font(.system(size: 17))
                    Spacer()
                    Text(efforts.indices.contains(selectedIndex) ? efforts[selectedIndex].name : "不支持")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 10)
                if !efforts.isEmpty {
                    DSHRemoteReasoningSlider(count: efforts.count, selectedIndex: selectedIndex,
                                             labels: efforts.map(\.name)) { index in
                        guard efforts.indices.contains(index) else { return }
                        selection = DSHModelSelection(provider: selection.provider, model: selection.model,
                                                      reasoningEffort: efforts[index].id)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(width: 330, height: 190, alignment: .top)
        .foregroundStyle(.primary)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private func dshCatalogModel(catalog: DSHModelCatalog?, selection: DSHModelSelection) -> DSHModelCatalogModel? {
    catalog?.groups.first(where: { $0.id == selection.provider })?.models.first {
        $0.id == selection.model || $0.name == selection.model || selection.model.hasSuffix("/\($0.id)")
    }
}

private func dshModelEffortID(catalog: DSHModelCatalog?, selection: DSHModelSelection,
                             efforts: [DSHModelReasoningEffort]) -> String {
    selection.reasoningEffort
        ?? dshCatalogModel(catalog: catalog, selection: selection)?.reasoning?.defaultEffort
        ?? efforts.first?.id ?? ""
}

private func dshModelEfforts(catalog: DSHModelCatalog?, selection: DSHModelSelection,
                             fallback: [DSHModelReasoningEffort]) -> [DSHModelReasoningEffort] {
    if let item = dshCatalogModel(catalog: catalog, selection: selection) {
        return dshOrderedReasoningEfforts(item.reasoning?.efforts ?? [])
    }
    return dshOrderedReasoningEfforts(fallback)
}

/// Keeps slider positions tied to the catalog's semantic intelligence fields,
/// even when a provider returns those fields in a different order.
func dshOrderedReasoningEfforts(_ efforts: [DSHModelReasoningEffort]) -> [DSHModelReasoningEffort] {
    efforts.enumerated().sorted { lhs, rhs in
        let left = dshReasoningRank(lhs.element)
        let right = dshReasoningRank(rhs.element)
        return left == right ? lhs.offset < rhs.offset : left < right
    }.map(\.element)
}

func dshReasoningRank(_ effort: DSHModelReasoningEffort) -> Int {
    dshReasoningRankOf(id: effort.id, name: effort.name)
}

func dshReasoningRankOf(id: String, name: String) -> Int {
    let value = "\(id) \(name)".lowercased()
    // Match the Harness effort vocabulary from least to most capable. Check
    // xhigh before high because its id contains "high".
    if value.contains("none") || value.contains("off") || value.contains("不思考") { return 0 }
    if value.contains("minimal") || value.contains("最小") { return 1 }
    if value.contains("low") || value.contains("低") { return 2 }
    if value.contains("medium") || value.contains("中") { return 3 }
    if value.contains("max") || value.contains("ultra") || value.contains("xhigh") || value.contains("极高") { return 5 }
    if value.contains("high") || value.contains("高级") || value.contains("高") { return 4 }
    // Unknown names should render as a neutral, midrange effort rather than
    // pretending they are the least capable option.
    return 3
}

/// A model's glyph uses the absolute semantic effort rank, rather than its
/// position in whichever subset the provider happened to expose. For example,
/// High keeps the same meter position in `[low, medium, high]` and
/// `[none, minimal, low, medium, high, xhigh]`.
func dshReasoningIntensity(_ efforts: [DSHModelReasoningEffort], selectedEffortID: String) -> Double {
    let ordered = dshOrderedReasoningEfforts(efforts)
    guard !ordered.isEmpty else { return 0.58 }
    let index = dshNearestReasoningEffortIndex(ordered, to: selectedEffortID)
    return Double(dshReasoningRank(ordered[index])) / 5
}

/// Index of the effort that best matches a persisted effort id. Exact id
/// wins; otherwise the semantically nearest rank wins (the server and the
/// catalog sometimes use different id spaces, e.g. "xhigh" vs "high").
/// Never falls back to 0 blindly: an unmatched id used to slam the meter to
/// minimum even when the model was actually running at maximum.
func dshNearestReasoningEffortIndex(_ efforts: [DSHModelReasoningEffort], to effortID: String) -> Int {
    if let exact = efforts.firstIndex(where: { $0.id == effortID }) { return exact }
    guard !efforts.isEmpty else { return 0 }
    let want = dshReasoningRankOf(id: effortID, name: "")
    var best = 0
    var bestDistance = Int.max
    for (index, effort) in efforts.enumerated() {
        let distance = abs(dshReasoningRank(effort) - want)
        if distance < bestDistance {
            bestDistance = distance
            best = index
        }
    }
    return best
}

private func remoteStroke(width: CGFloat) -> StrokeStyle {
    StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
}

private struct DSHRemoteOpenFolderShape: Shape {
    func path(in rect: CGRect) -> Path {
        let point = remotePointMapper(in: rect)
        var path = Path()

        // Back folder and raised tab.
        path.move(to: point(4.6, 23.8))
        path.addLine(to: point(3.9, 8.8))
        path.addQuadCurve(to: point(7.2, 5.4), control: point(4.0, 5.4))
        path.addLine(to: point(12.6, 5.4))
        path.addQuadCurve(to: point(15.0, 6.7), control: point(14.0, 5.4))
        path.addLine(to: point(17.1, 9.4))
        path.addLine(to: point(23.7, 9.4))
        path.addQuadCurve(to: point(27.4, 13.0), control: point(27.4, 9.4))

        // Open front leaf.
        path.move(to: point(5.5, 13.0))
        path.addQuadCurve(to: point(8.6, 10.9), control: point(6.4, 10.9))
        path.addLine(to: point(26.8, 10.9))
        path.addQuadCurve(to: point(28.2, 14.1), control: point(29.4, 11.7))
        path.addLine(to: point(24.1, 23.4))
        path.addQuadCurve(to: point(20.9, 26.0), control: point(23.2, 26.0))
        path.addLine(to: point(8.0, 26.0))
        path.addQuadCurve(to: point(4.8, 23.0), control: point(4.7, 26.0))
        path.closeSubpath()
        return path
    }
}

private struct DSHRemoteClosedFolderShape: Shape {
    func path(in rect: CGRect) -> Path {
        let point = remotePointMapper(in: rect)
        var path = Path()
        path.move(to: point(4.8, 24.0))
        path.addLine(to: point(4.8, 10.6))
        path.addQuadCurve(to: point(7.8, 7.5), control: point(4.8, 7.5))
        path.addLine(to: point(13.0, 7.5))
        path.addQuadCurve(to: point(15.2, 8.8), control: point(14.3, 7.5))
        path.addLine(to: point(17.0, 11.2))
        path.addLine(to: point(24.2, 11.2))
        path.addQuadCurve(to: point(27.2, 14.2), control: point(27.2, 11.2))
        path.addLine(to: point(27.2, 24.0))
        path.addQuadCurve(to: point(24.2, 27.0), control: point(27.2, 27.0))
        path.addLine(to: point(7.8, 27.0))
        path.addQuadCurve(to: point(4.8, 24.0), control: point(4.8, 27.0))
        path.closeSubpath()
        path.move(to: point(5.2, 15.0))
        path.addLine(to: point(26.8, 15.0))
        return path
    }
}

private struct DSHRemoteTerminalMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.30, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.50, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

private func remotePointMapper(in rect: CGRect) -> (_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    { x, y in
        CGPoint(x: rect.minX + (x / 32) * rect.width,
                y: rect.minY + (y / 32) * rect.height)
    }
}

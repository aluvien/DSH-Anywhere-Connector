import SwiftUI

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
struct DSHRemoteReasoningGlyph: View {
    var intensity: Double

    private var clamped: Double { min(1, max(0, intensity)) }
    private var arcEnd: Double { 0.375 + 0.18 + (0.32 * clamped) }
    private var needleAngle: Double { 135 - (195 * clamped) }

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
    let count: Int
    let selectedIndex: Int
    let onChanged: (Int) -> Void
    /// Tick labels under the rail (effort names, already ordered). Empty keeps
    /// the legacy dot-only rail.
    let labels: [String]

    @State private var liveIndex: Int

    init(count: Int, selectedIndex: Int, labels: [String] = [], onChanged: @escaping (Int) -> Void) {
        self.count = max(1, count)
        self.selectedIndex = min(max(0, selectedIndex), max(0, count - 1))
        // Only as many labels as ticks; extras would have no tick to sit on.
        self.labels = Array(labels.prefix(self.count))
        self.onChanged = onChanged
        _liveIndex = State(initialValue: self.selectedIndex)
    }

    private var lastIndex: Int { max(0, count - 1) }
    private var showsLabels: Bool { labels.count == count && count > 1 }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let metrics = DSHReasoningRailMetrics(width: proxy.size.width)
                let normalized = lastIndex == 0 ? 0 : CGFloat(liveIndex) / CGFloat(lastIndex)
                let knobX = metrics.x(for: normalized)

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color(.systemBackground))
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                        }

                    // Fill runs from the rail's left inset to the knob center:
                    // ending at the knob edge overshoots it at minimum and
                    // leaves the knob half-uncovered nowhere in between.
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: max(metrics.knobDiameter / 2, knobX - metrics.outerInset),
                               height: proxy.size.height - metrics.outerInset * 2)
                        .padding(.leading, metrics.outerInset)

                    ForEach(0..<count, id: \.self) { index in
                        let fraction = lastIndex == 0 ? 0 : CGFloat(index) / CGFloat(lastIndex)
                        Circle()
                            .fill(index <= liveIndex ? Color.white.opacity(0.20) : Color(.systemGray4))
                            .frame(width: 13, height: 13)
                            .position(x: metrics.x(for: fraction),
                                      y: proxy.size.height / 2)
                    }

                    Circle()
                        .fill(Color.white)
                        .overlay { Circle().stroke(Color.accentColor, lineWidth: 3) }
                        .frame(width: metrics.knobDiameter, height: metrics.knobDiameter)
                        .position(x: knobX, y: proxy.size.height / 2)
                }
                .contentShape(Capsule(style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let raw = metrics.index(for: value.location.x, lastIndex: lastIndex)
                            if raw != liveIndex {
                                liveIndex = raw
                                onChanged(raw)
                            }
                        }
                )
                .animation(.spring(response: 0.25, dampingFraction: 0.84), value: liveIndex)
            }
            .frame(height: 64)

            if showsLabels {
                GeometryReader { proxy in
                    let metrics = DSHReasoningRailMetrics(width: proxy.size.width)
                    ZStack(alignment: .topLeading) {
                        ForEach(0..<count, id: \.self) { index in
                            let fraction = lastIndex == 0 ? 0 : CGFloat(index) / CGFloat(lastIndex)
                            // Exact tick centers, no edge clamping: clamping
                            // kept the frame on-rails but moved edge labels
                            // off their dots. Short effort names never reach
                            // the frame edges; long ones middle-truncate.
                            Text(labels[index])
                                .font(.system(size: 11, weight: index == liveIndex ? .semibold : .regular))
                                .foregroundStyle(index == liveIndex ? .primary : .secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .truncationMode(.middle)
                                .frame(width: metrics.labelWidth(for: count), alignment: .center)
                                .position(x: metrics.x(for: fraction), y: 9)
                        }
                    }
                }
                .frame(height: 18)
                .animation(.spring(response: 0.25, dampingFraction: 0.84), value: liveIndex)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(by: 1)
            case .decrement: step(by: -1)
            @unknown default: break
            }
        }
        .onChange(of: selectedIndex) { _, newValue in
            liveIndex = min(max(0, newValue), lastIndex)
        }
    }

    private var accessibilityLabel: String {
        showsLabels ? "思考深度，\(labels.joined(separator: "、"))" : "思考深度"
    }

    private var accessibilityValue: String {
        guard labels.indices.contains(liveIndex) else { return "\(liveIndex + 1) / \(count)" }
        return labels[liveIndex]
    }

    private func step(by delta: Int) {
        let next = min(max(0, liveIndex + delta), lastIndex)
        guard next != liveIndex else { return }
        liveIndex = next
        onChanged(next)
    }
}

/// Single source of truth for rail geometry, shared by the rail, the dots,
/// the knob and the tick labels so all three stay centered on one x.
private struct DSHReasoningRailMetrics {
    let outerInset: CGFloat = 7
    let knobDiameter: CGFloat = 42
    let railWidth: CGFloat
    let knobTravel: CGFloat

    init(width: CGFloat) {
        self.railWidth = max(1, width - outerInset * 2)
        self.knobTravel = max(1, railWidth - knobDiameter)
    }

    /// X center for a 0...1 fraction along the rail.
    func x(for fraction: CGFloat) -> CGFloat {
        outerInset + knobDiameter / 2 + knobTravel * min(max(0, fraction), 1)
    }

    func index(for locationX: CGFloat, lastIndex: Int) -> Int {
        let position = min(max(locationX - outerInset - knobDiameter / 2, 0), knobTravel)
        guard lastIndex > 0 else { return 0 }
        return Int(round((position / knobTravel) * CGFloat(lastIndex)))
    }

    /// Column width for tick labels. Labels sit on exact tick centers, so
    /// this only bounds truncation: short names never reach the edges.
    func labelWidth(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return min(64, max(40, (railWidth + outerInset * 2) / CGFloat(count)))
    }
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
    if value.contains("max") || value.contains("ultra") || value.contains("xhigh") || value.contains("极高") { return 4 }
    if value.contains("high") || value.contains("高级") || value.contains("高") { return 3 }
    if value.contains("medium") || value.contains("中") { return 2 }
    if value.contains("low") || value.contains("minimal") || value.contains("低") { return 1 }
    return 2
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

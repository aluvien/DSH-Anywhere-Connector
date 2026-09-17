import SwiftUI

struct ToolActivityCard: View {
    let tool: DSHToolActivity
    @State private var isExpanded: Bool

    init(tool: DSHToolActivity) {
        self.tool = tool
        _isExpanded = State(initialValue: !Self.isShellTool(tool.name))
    }

    private var isComplete: Bool {
        ["completed", "complete", "success", "succeeded"].contains(tool.status.lowercased())
    }

    /// Pulse only while actually running: a failed tool is settled, and a
    /// forever-pulsing gear reads as "still working".
    private var isRunning: Bool {
        tool.status.lowercased() == "running"
    }

    private var hasDetail: Bool {
        !(tool.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard hasDetail else { return }
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: isComplete ? "checkmark.circle.fill" : "gearshape.2.fill")
                        .foregroundStyle(isComplete ? .green : .orange)
                        .symbolEffect(.pulse, isActive: isRunning)
                    // Web-style one-liner ("读取 · docs/x.md"): the Chinese
                    // verb plus the call target, so the row says what the
                    // model is doing without opening it.
                    Text(DSHToolPresentation.headline(for: tool))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(DSHToolPresentation.statusText(tool.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if hasDetail {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, let detail = tool.detail, !detail.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("\(DSHToolPresentation.headline(for: tool))，\(DSHToolPresentation.statusText(tool.status))")
    }

    private static func isShellTool(_ name: String) -> Bool {
        let value = name.lowercased()
        return ["bash", "shell", "terminal", "exec_command", "command"]
            .contains { value.contains($0) }
    }
}

struct ToolActivityCard_Previews: PreviewProvider {
    static var previews: some View {
        ToolActivityCard(tool: DSHToolActivity(id: "tool", name: "read_project", status: "running", detail: "Reading files"))
            .padding()
    }
}

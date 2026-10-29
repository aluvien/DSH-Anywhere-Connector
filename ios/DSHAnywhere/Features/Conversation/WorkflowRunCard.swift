import SwiftUI

struct DSHWorkflowsPanel: View {
    let sessionID: String
    var parentID: String? = nil
    var child: DSHSubagentCatalog.Entry? = nil
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.connectionState != .connected { Text("离线，显示已缓存的工作流记录。").font(.caption).foregroundStyle(.secondary) }
                    if model.workflows(for: sessionID).isEmpty { Text("暂无工作流记录").foregroundStyle(.secondary) }
                    ForEach(model.workflows(for: sessionID).reversed()) { run in
                        DSHWorkflowRunCard(sessionID: sessionID, run: run)
                    }
                }
                .padding()
            }
            .navigationTitle("工作流记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .refreshable {
                if model.connectionState == .connected {
                    if let parentID, let child { model.openSubagent(child, parentID: parentID) }
                    else { model.openSession(sessionID) }
                }
            }
        }
    }
}

struct DSHWorkflowRunCard: View {
    let sessionID: String
    let run: DSHWorkflowRun
    @EnvironmentObject private var model: DSHAppModel
    @State private var expanded = false
    @State private var expandedPhases: Set<String> = []
    @State private var watcherToken = UUID()
    @State private var selectedChild: DSHSubagentCatalog.Entry?
    @State private var pendingChildID: String?
    @State private var navigationError: String?

    init(sessionID: String, run: DSHWorkflowRun, initiallyExpanded: Bool = false,
         initiallyExpandedPhases: Set<String> = []) {
        self.sessionID = sessionID
        self.run = run
        _expanded = State(initialValue: initiallyExpanded)
        _expandedPhases = State(initialValue: initiallyExpandedPhases)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    if run.members.isEmpty { Text("没有启动成员").foregroundStyle(.secondary) }
                    ForEach(run.phases) { phase in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expandedPhases.contains(phase.id) },
                            set: { if $0 { expandedPhases.insert(phase.id) } else { expandedPhases.remove(phase.id) } }
                        )) {
                            VStack(spacing: 0) { ForEach(phase.members) { member in memberRow(member) } }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(phase.name.map { $0.isEmpty ? "空阶段名" : $0 } ?? "未分阶段")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                                Text(memberSummary(phase.members)).font(.caption).foregroundStyle(Color.secondary)
                            }
                            .frame(minHeight: 44, alignment: .leading)
                        }
                    }
                    if let start = run.startedAt, let end = run.finishedAt, end >= start {
                        Text("\(run.status == "interrupted" ? "记录跨度" : "用时") \((end - start) / 1_000) 秒").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.connectionState != .connected { Text("离线记录，运行状态待重新同步。").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.top, 8)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Label(run.name.isEmpty ? "工作流" : run.name, systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        status(run.status)
                        Text("· \(run.members.count) 个成员").foregroundStyle(Color.secondary)
                    }.font(.caption)
                    let abnormal = run.members.filter { ["failed", "cancelled", "interrupted"].contains($0.status) }
                    if !abnormal.isEmpty {
                        Label("成员：" + memberSummary(abnormal), systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(Color.orange)
                    }
                }
                .frame(minHeight: 44, alignment: .leading)
            }
            if let navigationError { Text(navigationError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .onAppear { if expanded { model.watchSubagents(for: sessionID, token: watcherToken) } }
        .onChange(of: expanded) { _, value in
            if value { model.watchSubagents(for: sessionID, token: watcherToken) }
            else { model.unwatchSubagents(for: sessionID, token: watcherToken) }
        }
        .onDisappear { model.unwatchSubagents(for: sessionID, token: watcherToken) }
        .sheet(item: $selectedChild) { child in
            NavigationStack {
                DSHSubagentRecord(parentID: sessionID, child: child).environmentObject(model)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selectedChild = nil } } }
            }
        }
    }
    private func memberRow(_ member: DSHWorkflowRun.Member) -> some View {
        Button { open(member) } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(member.label.isEmpty ? "空成员名" : member.label)
                    .font(.subheadline).foregroundStyle(Color.accentColor)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                if pendingChildID == member.childId { ProgressView() }
                else { status(member.status).font(.caption).fixedSize(horizontal: true, vertical: false) }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10).frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pendingChildID != nil)
        .accessibilityHint("打开关联子任务的执行记录")
    }
    @ViewBuilder private func status(_ value: String) -> some View {
        let appearance = DSHWorkflowStatus.appearance(value)
        Label(appearance.title, systemImage: appearance.icon).foregroundStyle(appearance.color)
    }
    private func memberSummary(_ members: [DSHWorkflowRun.Member]) -> String {
        let order = ["completed", "running", "failed", "cancelled", "interrupted"]
        return order.compactMap { status -> String? in
            let count = members.filter { $0.status == status }.count
            return count == 0 ? nil : "\(DSHWorkflowStatus.appearance(status).title) \(count)"
        }.joined(separator: " · ")
    }
    private func open(_ member: DSHWorkflowRun.Member) {
        guard pendingChildID == nil else { return }
        pendingChildID = member.childId
        navigationError = nil
        Task { @MainActor in
            defer { pendingChildID = nil }
            do { selectedChild = try await model.workflowChild(member.childId, parentID: sessionID) }
            catch { navigationError = error.localizedDescription }
        }
    }
}

enum DSHWorkflowStatus {
    static func appearance(_ value: String) -> (title: String, icon: String, color: Color) {
        switch value {
        case "running": ("运行中", "circle.dotted", .accentColor)
        case "completed": ("已完成", "checkmark.circle", .green)
        case "failed": ("失败", "exclamationmark.circle", .red)
        case "cancelled": ("已取消", "xmark.circle", .secondary)
        case "interrupted": ("已中断", "pause.circle", .orange)
        default: (value, "questionmark.circle", .secondary)
        }
    }
}

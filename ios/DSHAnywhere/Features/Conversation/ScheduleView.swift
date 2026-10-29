import SwiftUI

struct DSHSchedulePanel: View {
    let sessionID: String
    var parentID: String? = nil
    var mode: String? = nil
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var loading = false
    @State private var error: String?
    @State private var readAt = Date()
    private var snapshot: DSHScheduleProjection? { model.scheduleState(for: sessionID) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("提醒由电脑上的原始会话执行，该会话需要保持开启。").font(.subheadline).foregroundStyle(.secondary)
                    if model.connectionState != .connected || snapshot?.available == false { Text("离线或状态待同步，显示已缓存的提醒。").font(.caption).foregroundStyle(.secondary) }
                    if loading { ProgressView("读取电脑提醒…") }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    Button("刷新电脑状态") { Task { await load() } }.disabled(loading || model.connectionState != .connected)
                }
                if let snapshot {
                    if !snapshot.supported { Text("此电脑未启用 Harness 定时提醒能力。").foregroundStyle(.secondary) }
                    else if snapshot.items.isEmpty { Text(snapshot.available ? "当前会话没有待执行的提醒。" : "尚未获得可用的提醒状态。").foregroundStyle(.secondary) }
                    else {
                        Section("待执行提醒 · \(snapshot.items.count)") {
                            ForEach(snapshot.items.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }) { item in
                                if model.connectionState == .connected && snapshot.available {
                                    TimelineView(.periodic(from: .now, by: 30)) { context in row(item, now: context.date) }
                                } else { row(item, now: readAt) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("定时提醒").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task(id: "\(model.machineID):\(sessionID):\(model.connectionState)") { if model.connectionState == .connected { await load() } }
            .refreshable { await load() }
        }
    }
    private func row(_ item: DSHScheduleRecord, now: Date) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.frequencyLabel).font(.subheadline.weight(.semibold))
                Text(item.prompt).fixedSize(horizontal: false, vertical: true).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if let date = item.date {
                    Text(date, format: .dateTime.year().month().day().hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                    if date <= now { Text("已到期，等待电脑端处理").font(.caption).foregroundStyle(.orange) }
                } else { Text(item.scheduledAt).font(.caption).foregroundStyle(.secondary) }
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
    }
    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do { try await model.loadSchedules(sessionID: sessionID, parentID: parentID, mode: mode); try Task.checkCancellation(); readAt = Date() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

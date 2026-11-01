import SwiftUI

private struct DSHFeedbackDraft: Codable, Equatable {
    var base: DSHFeedbackItem?
    var rating = "positive"
    var note = ""
    var category = ""
}

struct DSHFeedbackEditor: View {
    let sessionID: String
    let messageID: String
    let initialRating: String
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DSHFeedbackDraft()
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var initialized = false
    private var current: DSHFeedbackItem? { model.feedback(for: messageID, in: sessionID) }
    private var conflict: Bool { loaded && draft.base?.version != current?.version }
    private var draftKey: String {
        "dsh.feedback.draft." + Data([model.machineID, sessionID, messageID].joined(separator: "\u{0}").utf8).base64EncodedString()
    }
    private let categories = [("", "不分类"), ("task-result", "任务结果"), ("instruction-following", "指令遵循"),
        ("product-interaction", "产品交互"), ("service-stability", "服务稳定性"), ("resource-cost", "资源消耗"),
        ("security-privacy-permission", "安全、隐私与权限"), ("other", "其他")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("评价", selection: $draft.rating) {
                        Text("有帮助").tag("positive")
                        Text("需要改进").tag("negative")
                    }.pickerStyle(.segmented)
                    if draft.rating == "negative" {
                        Picker("分类", selection: $draft.category) {
                            ForEach(categories, id: \.0) { value, label in Text(label).tag(value) }
                        }
                    }
                    TextField("备注（可选）", text: $draft.note, axis: .vertical)
                        .lineLimit(4...12)
                } footer: { Text("评价保存到这条回答所属的 Harness 会话。") }
                    .disabled(busy)
                if !loaded {
                    Section {
                        if busy { ProgressView("正在读取当前评价…") }
                        else { Button("读取当前评价") { Task { await refresh() } } }
                    }
                }
                if conflict {
                    Section("评价已在其他端更新") {
                        if let current {
                            Text(current.rating == "positive" ? "最新评价：有帮助" : "最新评价：需要改进")
                            if let note = current.note { Text(note).textSelection(.enabled) }
                        } else { Text("其他端已删除评价") }
                        Button("采用最新版本，保留我的输入") { draft.base = current }
                        Button("载入最新评价") { loadCurrent() }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                Section {
                    Button("保存评价") { submit("put") }
                        .disabled(!loaded || busy || conflict || model.connectionState != .connected)
                    if draft.base != nil {
                        Button("删除评价", role: .destructive) { submit("delete") }
                            .disabled(!loaded || busy || conflict || model.connectionState != .connected)
                    }
                    Button("刷新当前状态") { Task { await refresh() } }.disabled(busy)
                }
            }
            .navigationTitle("回答评价").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .task {
                guard !initialized else { return }; initialized = true
                let stored = UserDefaults.standard.data(forKey: draftKey).flatMap { try? JSONDecoder().decode(DSHFeedbackDraft.self, from: $0) }
                if let stored { draft = stored }
                else { draft.rating = initialRating }
                await refresh()
                if stored == nil, loaded {
                    draft.base = current
                    draft.note = current?.note ?? ""
                    draft.category = current?.category ?? ""
                }
            }
            .onChange(of: draft) { _, value in
                if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: draftKey) }
            }
        }
    }

    private func loadCurrent() {
        draft = DSHFeedbackDraft(base: current, rating: current?.rating ?? initialRating,
            note: current?.note ?? "", category: current?.category ?? "")
    }
    private func refresh() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await model.loadFeedback(for: sessionID); loaded = true }
        catch { self.error = error.localizedDescription; loaded = false }
    }
    private func submit(_ action: String) {
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await model.updateFeedback(messageID: messageID, in: sessionID, action: action, rating: draft.rating,
                    note: draft.note, category: draft.rating == "negative" && !draft.category.isEmpty ? draft.category : nil,
                    ifVersion: draft.base?.version)
                UserDefaults.standard.removeObject(forKey: draftKey)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

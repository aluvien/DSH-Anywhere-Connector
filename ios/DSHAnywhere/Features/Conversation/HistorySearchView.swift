import SwiftUI

struct DSHHistorySearchResults: View {
    let query: String
    var sessionID: String? = nil
    var parentID: String? = nil
    var mode: String? = nil
    var onSelect: ((DSHSearchHit) -> Void)? = nil
    @EnvironmentObject private var model: DSHAppModel
    @State private var result: DSHSearchResults?
    @State private var error: String?
    @State private var loading = false
    @State private var epoch = UUID()
    @State private var moreTask: Task<Void, Never>?
    private var identity: String { "\(model.machineID)|\(model.connectionState)|\(sessionID ?? "")|\(query)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(sessionID == nil ? "电脑上的对话内容" : "对话内搜索结果").font(.headline)
                if let error {
                    Text(error).font(.subheadline).foregroundStyle(.red).textSelection(.enabled)
                    Button("重新搜索") { moreTask?.cancel(); moreTask = Task { await load(reset: true) } }.disabled(loading)
                }
                ForEach(result?.items ?? []) { hit in
                    if let onSelect { Button { onSelect(hit) } label: { hitLabel(hit) }.buttonStyle(.plain) }
                    else { NavigationLink { ConversationView(sessionID: hit.sessionId, initialLocation: hit) } label: { hitLabel(hit) }.buttonStyle(.plain) }
                }
                if loading { ProgressView("正在搜索电脑历史…") }
                if let result, result.items.isEmpty, !loading { Text("未找到匹配内容").foregroundStyle(.secondary) }
                if let result, result.bounded == true { Text("当前 Harness 仅提供有限结果；升级电脑端后可继续分页及精确定位。").font(.caption).foregroundStyle(.secondary) }
                if result?.nextCursor != nil {
                    Button("加载更多结果") { moreTask?.cancel(); moreTask = Task { await load(reset: false) } }
                        .disabled(loading || model.connectionState != .connected)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: identity) {
            moreTask?.cancel(); epoch = UUID(); result = nil; error = nil; loading = false
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation() } catch { return }
            await load(reset: true)
        }
        .onDisappear { epoch = UUID(); moreTask?.cancel() }
    }
    private func hitLabel(_ hit: DSHSearchHit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if sessionID == nil { Text(hit.session?.title ?? hit.sessionId).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary) }
            Text(hit.snippet).font(.subheadline).foregroundStyle(Color.primary).lineLimit(5).multilineTextAlignment(.leading)
            VStack(alignment: .leading, spacing: 3) {
                if let time = hit.time { Text(Date(timeIntervalSince1970: Double(time) / 1_000), format: .dateTime.year().month().day().hour().minute()) }
                if hit.surface == "shadowed" { Text("已被上下文替换的记录") }
                if hit.surface == "log-only" { Text("执行记录") }
            }.font(.caption).foregroundStyle(Color.secondary)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(12).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
    private func load(reset: Bool) async {
        guard !loading else { return }
        if reset { epoch = UUID(); result = nil }
        let token = epoch
        loading = true; error = nil
        defer { if epoch == token { loading = false } }
        do {
            let page = try await model.searchHistory(query: query, sessionID: sessionID, cursor: reset ? nil : result?.nextCursor, parentID: parentID, mode: mode)
            try Task.checkCancellation()
            guard epoch == token else { return }
            var next = page
            let earlier = reset ? [] : (result?.items ?? [])
            let seen = Set(earlier.map(\.id))
            next.items = earlier + page.items.filter { !seen.contains($0.id) }
            result = next
        } catch is CancellationError { }
        catch { if epoch == token { self.error = error.localizedDescription } }
    }
}

struct DSHHistorySearchPanel: View {
    let sessionID: String
    var parentID: String? = nil
    var mode: String? = nil
    let onSelect: (DSHSearchHit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                DSHHistorySearchResults(query: query, sessionID: sessionID, parentID: parentID, mode: mode) { hit in
                    dismiss(); onSelect(hit)
                }.padding()
            }
            .searchable(text: $query, prompt: "搜索完整对话和执行记录")
            .navigationTitle("搜索对话").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct DSHHistoryFocusView: View {
    let sessionID: String
    let focus: DSHHistoryFocus
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    private var focusedTool: DSHToolActivity? {
        guard focus.type.hasPrefix("tool/") else { return nil }
        let id = focus.data["subCallId"]?.executionString ?? focus.data["callId"]?.executionString ??
            focus.data["message"]?.executionObject["content"]?.executionArray.first?.executionObject["toolCallId"]?.executionString
        func find(_ tools: [DSHToolActivity]) -> DSHToolActivity? {
            for tool in tools {
                if tool.id == id || tool.nativeSequence == focus.nativeSequence { return tool }
                if let match = find(tool.children ?? []) { return match }
            }
            return nil
        }
        return find(model.tools(for: sessionID))
    }
    var body: some View {
        NavigationStack {
            if let tool = focusedTool {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ToolActivityCard(tool: tool, sessionID: sessionID, initiallyExpanded: true)
                        DisclosureGroup("定位的原生记录") { Text(DSHJSONValue.object(focus.data).executionPrettyJSON).font(.caption.monospaced()).textSelection(.enabled) }
                    }.padding()
                }.navigationTitle("工具搜索结果").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            } else if focus.type == "user/message" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("原始消息 · \(focus.nativeSequence)").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array((focus.data["content"]?.executionArray ?? []).enumerated()), id: \.offset) { _, part in
                            if let text = part.executionObject["text"]?.executionString { MarkdownBlockText(text: text).textSelection(.enabled) }
                        }
                        DisclosureGroup("原生记录详情") { Text(DSHJSONValue.object(focus.data).executionPrettyJSON).font(.caption.monospaced()).textSelection(.enabled) }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                }.navigationTitle("搜索定位").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            } else {
                DSHExecutionDetail(sessionID: sessionID, record: .init(nativeSequence: focus.nativeSequence, type: focus.type, time: focus.time, data: focus.data))
            }
        }
    }
}

extension DSHTranscriptSection {
    func contains(nativeSequence: Int64) -> Bool {
        func toolsContain(_ tools: [DSHToolActivity]) -> Bool {
            tools.contains { $0.nativeSequence == nativeSequence || toolsContain($0.children ?? []) }
        }
        switch self {
        case .turn(let block, let tools): return block.messages.contains { $0.nativeSequence == nativeSequence } || toolsContain(tools)
        case .row(let entry):
            switch entry {
            case .turn(let block): return block.messages.contains { $0.nativeSequence == nativeSequence }
            case .tool(let tool): return toolsContain([tool])
            case .command(let result): return result.nativeSequence == nativeSequence
            case .modelChange(let notice): return notice.nativeSequence == nativeSequence
            case .workflow(let run): return run.nativeSequence == nativeSequence
            case .execution(let notice): return notice.nativeSequence == nativeSequence
            case .historyGap: return false
            }
        }
    }
}

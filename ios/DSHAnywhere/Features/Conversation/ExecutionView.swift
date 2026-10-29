import SwiftUI

struct DSHExecutionPanel: View {
    let sessionID: String
    var parentID: String? = nil
    var mode: String? = nil
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var loading = false
    @State private var cursor: Int64?
    @State private var hasMore = true
    @State private var error: String?
    @State private var selected: DSHExecutionRecord?
    @State private var lifecycle: DSHExecutionLifecycle?
    @State private var search = ""
    @State private var expandedGroups: Set<String> = []
    private var records: [DSHExecutionRecord] {
        model.executionRecords(for: sessionID)
    }
    private var groups: [DSHExecutionGroup] {
        DSHExecutionGroup.build(records).compactMap { group in
            let filtered = group.records.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.type.localizedCaseInsensitiveContains(search) }
            return filtered.isEmpty ? nil : DSHExecutionGroup(id: group.id, title: group.title, records: filtered)
        }
    }
    var body: some View {
        NavigationStack {
            List {
                if model.connectionState != .connected { Text("离线，显示已缓存的执行记录。").font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if loading { ProgressView("正在读取执行记录…") }
                if hasMore {
                    Button(cursor == nil ? "读取电脑记录" : "加载更早记录") { Task { await load(older: true) } }
                        .disabled(loading || model.connectionState != .connected)
                }
                if let lifecycle { DSHExecutionLifecycleSection(lifecycle: lifecycle) }
                else if !loading { Text("此电脑尚未提供完整生命周期元数据；执行记录仍可阅读。").font(.caption).foregroundStyle(.secondary) }
                if records.isEmpty, !loading { Text("暂无已加载的执行记录").foregroundStyle(.secondary) }
                ForEach(groups) { group in
                    DisclosureGroup(isExpanded: Binding(get: { !search.isEmpty || expandedGroups.contains(group.id) },
                        set: { if $0 { expandedGroups.insert(group.id) } else { expandedGroups.remove(group.id) } })) {
                        ForEach(group.records) { record in
                            Button { selected = record } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(record.title).font(.subheadline.weight(.medium)).foregroundStyle(Color.primary)
                                    Text(context(record)).font(.caption).foregroundStyle(Color.secondary)
                                }.frame(minHeight: 44, alignment: .leading)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title).font(.headline).foregroundStyle(Color.primary)
                            Text("\(group.records.count) 条记录").font(.caption).foregroundStyle(Color.secondary)
                        }.frame(minHeight: 44, alignment: .leading)
                    }
                }
            }
            .navigationTitle("执行轨迹").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "查找已加载记录的类型")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .refreshable { await load(older: false) }
            .task { if model.connectionState == .connected { await load(older: false) } }
            .sheet(item: $selected) { record in NavigationStack { DSHExecutionDetail(sessionID: sessionID, record: record) } }
        }
    }
    private func context(_ record: DSHExecutionRecord) -> String {
        var parts = ["原生序号 \(record.nativeSequence)"]
        if let turn = record.turn { parts.append("轮次 \(turn)") }
        if let step = record.step { parts.append("步骤 \(step)") }
        return parts.joined(separator: " · ")
    }
    @MainActor private func load(older: Bool) async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let page = try await model.executionPage(sessionID: sessionID, beforeSeq: older ? cursor : nil, parentID: parentID, mode: mode)
            try Task.checkCancellation()
            cursor = page.beforeSeq; hasMore = page.hasMore
            if let next = page.lifecycle, lifecycle == nil || next.throughSeq >= lifecycle!.throughSeq { lifecycle = next }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

struct DSHExecutionLifecycleSection: View {
    let lifecycle: DSHExecutionLifecycle
    var body: some View {
        Section("本会话生命周期") {
            LabeledContent("创建时间") { Text(date(lifecycle.createdAt)).multilineTextAlignment(.trailing) }
            Text("自身记录 \(lifecycle.ownEventCount) 条 · 继承记录 \(lifecycle.inheritedEventCount) 条").font(.caption).foregroundStyle(.secondary)
            Text("已开始 \(lifecycle.turnsStarted) 轮 · 已结束 \(lifecycle.turnsEnded) 轮").font(.subheadline)
            Text("累计已结束轮次用时：\((lifecycle.endedTurnMilliseconds / 1000).formatted(.number.precision(.fractionLength(0...2)))) 秒").font(.subheadline)
            Text("仅计算自身 \(lifecycle.measuredTurns) 个有完整时间记录的轮次，不含继承历史、轮次间空闲及未结束轮次。").font(.caption).foregroundStyle(.secondary)
            if lifecycle.timingIncomplete { Text("部分原生轮次缺少配对或有效时间，累计用时不完整。").font(.caption).foregroundStyle(.orange) }
            if let open = lifecycle.openTurn {
                Text("轮次 \(open.turn) 尚无结束记录。当前是否运行以子任务目录为准。").font(.caption).foregroundStyle(.secondary)
                if let start = open.startedAt { Text("开始于 \(date(start))").font(.caption).foregroundStyle(.secondary) }
            }
            if let end = lifecycle.endDescription { Text("最近已结束轮次：\(end)").font(.caption).foregroundStyle(.secondary) }
            Text("自身回答 \(lifecycle.assistantMessages) 条 · 顶层工具调用 \(lifecycle.toolCalls) 次").font(.caption).foregroundStyle(.secondary)
            if let time = lifecycle.lastActivityAt { Text("最近记录：\(date(time))").font(.caption).foregroundStyle(.secondary) }
            Text("统计截至原生序号 \(lifecycle.throughSeq)，下拉刷新可更新。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func date(_ milliseconds: Double) -> String { Date(timeIntervalSince1970: milliseconds / 1000).formatted(date: .abbreviated, time: .standard) }
}

struct DSHExecutionNoticeCard: View {
    let sessionID: String
    let notice: DSHExecutionNotice
    @EnvironmentObject private var model: DSHAppModel
    @State private var expanded = false
    @State private var selected: DSHExecutionRecord?
    init(sessionID: String, notice: DSHExecutionNotice, initiallyExpanded: Bool = false) {
        self.sessionID = sessionID; self.notice = notice; _expanded = State(initialValue: initiallyExpanded)
    }
    private var retry: DSHExecutionRecord? { notice.latestRetry }
    private var summary: DSHExecutionRecord? { notice.records.last { $0.type == "compaction/summary" } }
    private var compactEnd: DSHExecutionRecord? { notice.records.last { $0.type == "compaction/end" } }
    private var title: String {
        switch notice.kind {
        case "retry":
            if retry == nil { return "重试启动记录" }
            switch notice.retryState {
            case "started": return "重试请求已开始"
            case "cancelled": return "重试等待已取消"
            default: return "等待重试"
            }
        case "compaction":
            if compactEnd?.data["error"] != nil { return "上下文压缩失败" }
            if notice.records.contains(where: { $0.type == "compaction/checkpoint" }) { return "上下文已压缩" }
            return compactEnd == nil ? "压缩未见结束记录" : "压缩结束，未见应用记录"
        case "prune": return "上下文裁剪记录"
        default: return notice.records.last?.title ?? "执行状态"
        }
    }
    private var countdownActive: Bool {
        let latestTurn = model.executionRecords(for: sessionID).last { $0.type == "turn/start" }
        return notice.canCountDown(connected: model.connectionState == .connected,
            sessionRunning: model.turnState(for: sessionID).lowercased() == "running", latestTurn: latestTurn?.turn)
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let retry {
                    Text("\(retry.data["mode"] == .string("always") ? "持续重试" : "重试") \(retry.data["retry"]?.executionInt.map(String.init) ?? "—")\(retry.data["maxRetries"]?.executionInt.map { "/\($0)" } ?? "") · \(retry.data["provider"]?.executionString ?? "")")
                    if let delay = retry.data["delayMs"]?.executionNumber { Text("计划等待 \(delay / 1_000, specifier: "%.1f") 秒") }
                    if let failure = retry.data["failure"] { DSHExecutionFailureView(value: failure) }
                    if notice.retryState == "scheduled", !countdownActive { Text("状态待与电脑同步，保留原计划等待时间。").font(.caption).foregroundStyle(Color.secondary) }
                }
                if let summary {
                    if let count = summary.data["shadowedSeqs"]?.executionArray.count { Text("覆盖 \(count) 条上下文记录") }
                    if let tokens = summary.data["shadowedTokenCount"]?.executionInt { Text("原上下文估算 \(tokens) tokens") }
                    if !summary.output.text.isEmpty { MarkdownBlockText(text: summary.output.text).textSelection(.enabled) }
                }
                if let error = compactEnd?.data["error"]?.executionString { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if notice.kind == "turn", let reason = notice.records.last?.data["reason"], reason != .string("completed") {
                    DSHExecutionEndReasonView(value: reason)
                }
                ForEach(notice.records) { record in
                    Button { selected = record } label: { Text("\(record.title) · #\(record.nativeSequence)").font(.caption).frame(minHeight: 44, alignment: .leading) }
                }
            }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(Color.primary)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: notice.kind == "retry" ? "arrow.clockwise" : notice.kind == "compaction" ? "arrow.down.right.and.arrow.up.left" : "info.circle")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Color.primary)
                if countdownActive, let retry, let time = retry.time, let delay = retry.data["delayMs"]?.executionNumber, delay.isFinite, delay >= 0 {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, ceil((Double(time) + delay - context.date.timeIntervalSince1970 * 1_000) / 1_000))
                        Text(seconds > 0 ? "约 \(seconds.formatted(.number.precision(.fractionLength(0)))) 秒后重试" : "等待电脑发起重试")
                            .font(.caption).foregroundStyle(Color.secondary)
                    }
                }
            }.frame(minHeight: 44, alignment: .leading)
        }
        .padding(12).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .sheet(item: $selected) { record in NavigationStack { DSHExecutionDetail(sessionID: sessionID, record: record) } }
    }
}

struct DSHExecutionDetail: View {
    let sessionID: String
    let record: DSHExecutionRecord
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rawExpanded = false
    @State private var rawDetails: String?
    private var requestStart: DSHExecutionRecord? {
        guard record.turn != nil, record.step != nil else { return nil }
        return model.executionRecords(for: sessionID).last {
            $0.nativeSequence < record.nativeSequence && $0.turn == record.turn && $0.step == record.step &&
                ($0.type == "step/start" || $0.type == "llm/retry-started")
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(record.title).font(.title3.weight(.semibold))
                Text("原生序号 \(record.nativeSequence)").font(.caption).foregroundStyle(.secondary)
                if let time = record.time { Text(Date(timeIntervalSince1970: Double(time) / 1_000), format: .dateTime.year().month().day().hour().minute().second()).font(.caption).foregroundStyle(.secondary) }
                if let start = requestStart?.time, let end = record.time, end >= start,
                   ["assistant/message", "assistant/attempt"].contains(record.type) {
                    Text("本次请求用时 \(Double(end - start) / 1_000, specifier: "%.2f") 秒")
                    if let first = record.firstTokenTime, first >= Double(start) { Text("首 token 延迟 \((first - Double(start)) / 1_000, specifier: "%.2f") 秒") }
                }
                let source = record.data["message"]?.executionObject["source"]?.executionObject ?? record.data
                if let provider = source["provider"]?.executionString { fact("模型服务", provider) }
                if let name = source["model"]?.executionString { fact("模型", name) }
                if record.type == "request/header", let config = record.data["header"]?.executionObject["config"]?.executionObject {
                    ForEach([("provider", "模型服务"), ("model", "模型"), ("reasoningEffort", "思考强度"), ("maxTokens", "最大输出 tokens"), ("temperature", "温度")], id: \.0) { key, title in
                        if let value = config[key] { fact(title, value.executionString ?? value.executionPrettyJSON) }
                    }
                }
                if let finish = record.finish { GroupBox("请求结束原因") { DSHExecutionEndReasonView(value: finish).frame(maxWidth: .infinity, alignment: .leading) } }
                if let usage = record.usage { GroupBox("本次用量") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach([("inputTokens", "输入（未缓存）"), ("outputTokens", "输出"), ("reasoningTokens", "思考"), ("cacheReadTokens", "缓存读取"), ("cacheWriteTokens", "缓存写入"), ("totalTokens", "总计")], id: \.0) { key, title in
                            if let value = usage.executionObject[key]?.executionNumber, value.isFinite { fact(title, value.formatted()) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } }
                if !record.output.text.isEmpty {
                    Text(record.type == "assistant/attempt" ? "未提交尝试的文本" : record.type == "compaction/summary" ? "压缩摘要" : "回答文本").font(.headline)
                    MarkdownBlockText(text: record.output.text).textSelection(.enabled)
                }
                if !record.output.reasoning.isEmpty {
                    DisclosureGroup("思考过程") { MarkdownBlockText(text: record.output.reasoning).textSelection(.enabled) }
                }
                DisclosureGroup("原生记录详情", isExpanded: $rawExpanded) {
                    if let rawDetails {
                        Text(rawDetails).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } else { ProgressView() }
                }
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("执行详情").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .task(id: rawExpanded) {
            guard rawExpanded, rawDetails == nil else { return }
            let data = record.data
            let json = await Task.detached(priority: .userInitiated) { DSHJSONValue.object(data).executionPrettyJSON }.value
            if !Task.isCancelled { rawDetails = json }
        }
    }
    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(Color.secondary)
            Text(value).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DSHExecutionFailureView: View {
    let value: DSHJSONValue
    var body: some View {
        let failure = value.executionObject
        VStack(alignment: .leading, spacing: 5) {
            Text(failure["message"]?.executionString ?? value.executionPrettyJSON).textSelection(.enabled)
            let diagnostics = [failure["code"]?.executionString,
                failure["status"]?.executionInt.map { "HTTP \($0)" }].compactMap { $0 }
            if !diagnostics.isEmpty { Text(diagnostics.joined(separator: " · ")).font(.caption.monospaced()).foregroundStyle(Color.secondary).textSelection(.enabled) }
            if let id = failure["requestId"]?.executionString { Text("请求 ID：\(id)").font(.caption).foregroundStyle(Color.secondary).textSelection(.enabled) }
        }
    }
}

private struct DSHExecutionEndReasonView: View {
    let value: DSHJSONValue
    var body: some View {
        let object = value.executionObject
        let kind = object["kind"]?.executionString ?? value.executionString
        VStack(alignment: .leading, spacing: 8) {
            Text(kind == "stop" ? "正常结束" : kind == "tool-calls" ? "请求工具调用" : DSHExecutionNotice.reasonLabel(kind))
            if let failure = object["failure"] ?? object["error"] { DSHExecutionFailureView(value: failure) }
            if kind == "aborted", let reason = object["reason"] {
                let cause = reason.executionObject["kind"]?.executionString ?? reason.executionString
                Text(["user": "用户取消", "parent": "父任务取消", "hook": "执行钩子取消", "disposed": "执行环境已释放", "legacy": "旧记录未提供取消原因"][cause ?? ""] ?? (cause ?? "取消原因未提供"))
                    .foregroundStyle(Color.secondary)
                if let detail = reason.executionObject["reason"]?.executionString { Text(detail).textSelection(.enabled) }
            }
        }
    }
}

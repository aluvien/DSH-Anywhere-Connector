import SwiftUI

struct ToolActivityCard: View {
    let tool: DSHToolActivity
    let sessionID: String?
    let isLive: Bool
    private let result: DSHToolResult?
    @State private var isExpanded: Bool
    @State private var showDetails = false
    @State private var showRawResult = false

    init(tool: DSHToolActivity, sessionID: String? = nil, isLive: Bool = false, initiallyExpanded: Bool? = nil) {
        self.tool = tool
        self.sessionID = sessionID
        self.isLive = isLive
        self.result = DSHToolResult.parse(tool)
        _isExpanded = State(initialValue: initiallyExpanded ?? !Self.isShellTool(tool.name))
    }

    private var isComplete: Bool {
        ["completed", "complete", "success", "succeeded"].contains(tool.status.lowercased())
    }

    /// Pulse only while actually running: a failed tool is settled, and a
    /// forever-pulsing gear reads as "still working".
    private var isRunning: Bool {
        tool.status.lowercased() == "running" && isLive
    }

    private var hasDetail: Bool {
        !(tool.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(tool.arguments?.isEmpty ?? true)
            || result != nil || !(tool.children?.isEmpty ?? true) || !(tool.attachments?.isEmpty ?? true)
            || tool.error != nil || tool.resultContent != nil
    }

    private var isFailed: Bool { tool.status == "failed" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard hasDetail else { return }
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: isFailed ? "xmark.circle.fill" : isComplete ? "checkmark.circle.fill" : "gearshape.2.fill")
                        .foregroundStyle(isFailed ? .red : isComplete ? .green : .orange)
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
                    Text(statusLabel)
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

            if isExpanded, hasDetail {
                ScrollView {
                    toolDetails
                }
                .frame(maxHeight: 240)
                .transition(.opacity.combined(with: .move(edge: .top)))
                Button("全屏查看输入和输出") { showDetails = true }
                    .font(.caption)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("\(DSHToolPresentation.headline(for: tool))，\(statusLabel)")
        .sheet(isPresented: $showDetails) {
            NavigationStack {
                ScrollView { toolDetails.padding() }
                    .navigationTitle(DSHToolPresentation.headline(for: tool))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showDetails = false }
                        }
                    }
            }
        }
    }

    private var toolDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let started = tool.startedAt, let finished = tool.finishedAt, finished >= started {
                Text("耗时 \(((finished - started) / 1000).formatted(.number.precision(.fractionLength(0...2)))) 秒")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let arguments = tool.arguments, !arguments.isEmpty {
                DisclosureGroup("输入") { Text(arguments).font(.caption.monospaced()).textSelection(.enabled) }
                    .font(.caption)
            }
            if let result {
                DSHToolResultContent(result: result, detail: tool.detail, sessionID: sessionID)
            } else if tool.status != "running", let detail = tool.detail, !detail.isEmpty {
                Text("输出").font(.caption.weight(.semibold))
                Text(detail).font(.caption.monospaced()).textSelection(.enabled)
            } else if tool.arguments == nil, let detail = tool.detail {
                Text(detail).font(.caption.monospaced()).textSelection(.enabled)
            }
            if let error = tool.error {
                Text(error.executionObject["message"]?.executionString ?? error.executionString ?? "工具执行失败，展开原始结果查看诊断。")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let attachments = tool.attachments, let sessionID, !attachments.isEmpty {
                MessageAttachmentsView(sessionID: sessionID, attachments: attachments, alignTrailing: false)
            }
            if let children = tool.children, !children.isEmpty {
                DisclosureGroup("子调用 · \(children.count)") {
                    ForEach(children) { child in AnyView(ToolActivityCard(tool: child, sessionID: sessionID, isLive: isLive && tool.status == "running")) }
                }.font(.subheadline)
            }
            if result != nil || tool.resultMeta != nil || tool.resultContent != nil || tool.error != nil {
                DisclosureGroup("原始结果", isExpanded: $showRawResult) {
                    if showRawResult {
                    if result != nil, let detail = tool.detail { Text(detail).font(.caption.monospaced()).textSelection(.enabled) }
                    if let error = tool.error { Text(error.executionPrettyJSON).font(.caption.monospaced()).textSelection(.enabled) }
                    if let meta = tool.resultMeta { Text(meta.executionPrettyJSON).font(.caption.monospaced()).textSelection(.enabled) }
                    if let content = tool.resultContent { Text(DSHJSONValue.array(content).executionPrettyJSON).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }.font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func isShellTool(_ name: String) -> Bool {
        let value = name.lowercased()
        return ["bash", "shell", "terminal", "exec_command", "command"]
            .contains { value.contains($0) }
    }

    private var statusLabel: String {
        tool.status == "running" && !isLive ? "未见结束记录" : DSHToolPresentation.statusText(tool.status)
    }
}

struct DSHToolResultContent: View {
    let result: DSHToolResult
    let detail: String?
    let sessionID: String?
    @State private var selectedFile: DSHFileReference?
    @State private var expanded: Set<Int>

    init(result: DSHToolResult, detail: String?, sessionID: String?, initiallyExpanded: Bool = false) {
        self.result = result; self.detail = detail; self.sessionID = sessionID
        let count: Int
        switch result { case .diff(let diffs): count = diffs.count
        case .search(let search): count = search.files?.count ?? 0
        default: count = 0 }
        _expanded = State(initialValue: initiallyExpanded ? Set(0..<count) : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch result {
            case .diff(let diffs):
                ForEach(Array(diffs.enumerated()), id: \.offset) { index, diff in
                    DisclosureGroup(isExpanded: expansion(index)) {
                        let lines = DSHToolDiffLine.lines(diff)
                        if (diff.oldText?.components(separatedBy: "\n").count ?? 0) + diff.newText.components(separatedBy: "\n").count > 2_000 {
                            Text("文件较大，按修改前和修改后展示完整内容。").font(.caption).foregroundStyle(.secondary)
                        }
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { line in
                                HStack(alignment: .top, spacing: 5) {
                                    Text(line.kind).frame(width: 12)
                                    Text(line.text.isEmpty ? " " : line.text).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.caption.monospaced()).textSelection(.enabled)
                                .foregroundStyle(line.kind == "+" ? Color.green : line.kind == "−" ? Color.red : Color.primary)
                                .padding(.vertical, 2)
                                .background(line.kind == "+" ? Color.green.opacity(0.08) : line.kind == "−" ? Color.red.opacity(0.08) : .clear)
                            }
                        }
                        fileButton(diff.path)
                    } label: { Label(diff.path, systemImage: "doc.badge.gearshape").foregroundStyle(Color.primary).font(.caption.weight(.semibold)) }
                }
            case .search(let search):
                Text("共 \(search.total) \(search.shape == "paths" ? "个路径" : "处匹配")").font(.caption.weight(.semibold))
                truncation(search.truncated)
                if search.total == 0 { Text("没有匹配结果").font(.caption).foregroundStyle(.secondary) }
                if search.shape == "paths", let paths = search.paths { ForEach(Array(paths.enumerated()), id: \.offset) { _, path in fileButton(path) } }
                if search.shape == "matches", let files = search.files {
                    ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                        DisclosureGroup(isExpanded: expansion(index)) {
                            ForEach(Array(file.matches.enumerated()), id: \.offset) { _, match in numberedLine(match.lineNumber, match.line) }
                            fileButton(file.path)
                        } label: { Text("\(file.path) · \(file.matches.count)").font(.caption).foregroundStyle(Color.primary) }
                    }
                }
            case .read(let read):
                fileButton(read.path)
                Text("从第 \(read.offset) 行起，展示 \(read.lines.count) 行；文件共 \(read.totalLines) 行")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(read.lines, id: \.number) { line in numberedLine(line.number, line.text) }
                }
            case .webSearch(let search):
                truncation(search.truncated)
                if let answer = search.answer, !answer.isEmpty { MarkdownBlockText(text: answer) }
                if search.sources.isEmpty { Text("未返回来源").font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(search.sources.enumerated()), id: \.offset) { index, source in
                    VStack(alignment: .leading, spacing: 4) {
                        if let url = DSHToolResult.webURL(source.url) {
                            Link("\(index + 1). \(source.title ?? source.url)", destination: url).font(.subheadline.weight(.semibold))
                        } else { Text(source.title ?? source.url).font(.subheadline.weight(.semibold)) }
                        Text(source.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let snippet = source.snippet { Text(snippet).font(.caption).textSelection(.enabled) }
                        if let date = source.publishedAt { Text(date).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
                }
            case .webFetch(let fetch):
                if let url = DSHToolResult.webURL(fetch.url) { Link(fetch.url, destination: url).font(.caption) }
                else { Text(fetch.url).font(.caption).textSelection(.enabled) }
                Text("HTTP \(fetch.statusCode)").font(.caption.weight(.semibold))
                truncation(fetch.truncated)
                if let detail { MarkdownBlockText(text: detail) }
            case .terminal(let output, let code, let signal):
                if let signal { Label("信号终止 · \(signal)", systemImage: "stop.circle").foregroundStyle(.orange).font(.caption.weight(.semibold)) }
                else if let code { Text("退出码 \(code)").font(.caption.weight(.semibold)).foregroundStyle(code == 0 ? Color.secondary : Color.red) }
                Text(output).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $selectedFile) { DSHRemoteFilePreview(reference: $0) }
    }

    @ViewBuilder private func fileButton(_ path: String) -> some View {
        if let sessionID {
            Button { selectedFile = DSHFileReference(sessionID: sessionID, path: path) } label: {
                Label(path, systemImage: "doc").font(.caption).multilineTextAlignment(.leading).frame(minHeight: 36)
            }
        } else { Text(path).font(.caption).textSelection(.enabled) }
    }
    @ViewBuilder private func truncation(_ truncated: Bool) -> some View {
        if truncated { Label("结果已截断，仅显示 Host 保留的部分", systemImage: "ellipsis.circle").font(.caption).foregroundStyle(.secondary) }
    }
    private func numberedLine(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(String(number)).foregroundStyle(.secondary).frame(minWidth: 28, alignment: .trailing)
            Text(text.isEmpty ? " " : text).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.caption.monospaced()).textSelection(.enabled)
    }
    private func expansion(_ index: Int) -> Binding<Bool> {
        Binding(get: { expanded.contains(index) }, set: { if $0 { expanded.insert(index) } else { expanded.remove(index) } })
    }
}

struct ToolActivityCard_Previews: PreviewProvider {
    static var previews: some View {
        ToolActivityCard(tool: DSHToolActivity(id: "tool", name: "read_project", status: "running", detail: "Reading files"))
            .padding()
    }
}

struct DSHJobsPanel: View {
    let sessionID: String
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.jobsState(for: sessionID)?.available == false || model.connectionState != .connected {
                    Text("后台任务状态暂未同步，以下为最后收到的信息。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let jobs = model.jobsState(for: sessionID)?.jobs, !jobs.isEmpty {
                    ForEach(jobs) { job in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                Text(job.label).font(.headline)
                                Spacer()
                                Text(statusLabel(job.status)).font(.caption)
                                    .foregroundStyle(job.status == "failed" ? Color.red : Color.secondary)
                            }
                            Text(job.kind).font(.caption).foregroundStyle(.secondary)
                            Text("开始于 \(Date(timeIntervalSince1970: Double(job.startedAt) / 1000).formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let finishedAt = job.finishedAt {
                                Text("耗时 \(max(0, (finishedAt - job.startedAt) / 1000)) 秒")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if model.jobsState(for: sessionID)?.available == true,
                                      model.connectionState == .connected,
                                      job.status == "running" || job.status == "stopping" {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text("已运行 \(max(0, Int64(context.date.timeIntervalSince1970) - job.startedAt / 1000)) 秒")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let detail = job.detail, !detail.isEmpty {
                                DisclosureGroup("详情") {
                                    Text(detail).font(.caption.monospaced()).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Text("暂无后台任务").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("后台任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "running": return "运行中"
        case "stopping": return "正在停止"
        case "completed": return "已完成"
        case "killed": return "已取消"
        case "failed": return "已失败"
        default: return status
        }
    }
}

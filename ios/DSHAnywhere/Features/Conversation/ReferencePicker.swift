import SwiftUI

struct DSHReferencePicker: View {
    let sessionID: String
    let onInsert: (String) -> Void
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "file"
    @State private var query = ""
    @State private var result: DSHReferenceCandidates?
    @State private var loading = false
    @State private var error: String?
    @State private var reload = UUID()
    private var requestKey: String { kind + "\u{0}" + query + "\u{0}" + reload.uuidString }

    init(sessionID: String, initialKind: String = "file", onInsert: @escaping (String) -> Void) {
        self.sessionID = sessionID; self.onInsert = onInsert
        _kind = State(initialValue: initialKind)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("引用类型", selection: $kind) {
                        Text("文件与目录").tag("file"); Text("会话").tag("session")
                    }.pickerStyle(.segmented)
                    TextField(kind == "file" ? "搜索工作区路径" : "搜索会话标题或路径", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if kind == "file", !query.isEmpty { Button("回到工作区根目录") { query = "" } }
                }
                if loading { ProgressView("正在读取电脑上的引用…") }
                if let error { Section { Text(error).foregroundStyle(.red); Button("重试") { reload = UUID() } } }
                if let result, result.kind == kind, result.query == query {
                    Section {
                        if result.items.isEmpty { Text("没有匹配的引用").foregroundStyle(.secondary) }
                        ForEach(result.items) { item in
                            HStack(alignment: .center, spacing: 12) {
                                Button {
                                    if item.kind == "directory", let path = item.path { query = path.hasSuffix("/") ? path : path + "/" }
                                    else { insert(item) }
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: item.kind == "session" ? "bubble.left.and.bubble.right" : item.kind == "directory" ? "folder" : "doc")
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.label).foregroundStyle(Color.primary).multilineTextAlignment(.leading)
                                            if item.sameWorkspace == true { Text("同一工作区").font(.caption).foregroundStyle(Color.secondary) }
                                            if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(Color.secondary).multilineTextAlignment(.leading) }
                                        }
                                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }.buttonStyle(.plain)
                                if item.kind == "directory" { Button("引用") { insert(item) }.font(.subheadline).frame(minHeight: 44) }
                            }
                        }
                    } footer: { Text(kind == "file" ? "点文件夹可继续浏览；点“引用”插入目录。引用会保留 Harness 的路径语法。" : "会话引用由电脑端准备上下文，保留真实会话身份。") }
                }
            }
            .navigationTitle("插入引用").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task(id: requestKey) {
                let identity = requestKey, expectedKind = kind, expectedQuery = query
                loading = true; error = nil; result = nil
                do {
                    try await Task.sleep(for: .milliseconds(200))
                    let value = try await model.referenceCandidates(in: sessionID, kind: expectedKind, query: expectedQuery)
                    guard !Task.isCancelled, requestKey == identity else { return }
                    result = value; loading = false
                } catch {
                    guard !Task.isCancelled, requestKey == identity else { return }
                    self.error = error.localizedDescription; loading = false
                }
            }
        }
    }
    private func insert(_ item: DSHReferenceCandidates.Item) { onInsert(item.insertion); dismiss() }
}

func dshAppendReference(_ insertion: String, to text: String) -> String {
    text + (text.isEmpty || text.last?.isWhitespace == true ? "" : " ") + insertion + " "
}

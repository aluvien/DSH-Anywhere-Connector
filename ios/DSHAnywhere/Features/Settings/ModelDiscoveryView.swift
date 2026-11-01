import SwiftUI

struct DSHModelDiscoveryView: View {
    let settingsNs: String
    let request: [String: DSHJSONValue]
    let existing: [DSHJSONValue]
    var onImport: (DSHDiscoveredModels, Set<String>) -> Void
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var temporaryKey = ""
    @State private var result: DSHDiscoveredModels?
    @State private var selected: Set<String> = []
    @State private var search = ""
    @State private var busy = false
    @State private var error: String?
    @State private var origin: [String]?
    @State private var query: Task<Void, Never>?
    init(settingsNs: String, request: [String: DSHJSONValue], existing: [DSHJSONValue], initialModels: DSHDiscoveredModels? = nil, onImport: @escaping (DSHDiscoveredModels, Set<String>) -> Void) {
        self.settingsNs = settingsNs; self.request = request; self.existing = existing; self.onImport = onImport
        _result = State(initialValue: initialModels)
        _selected = State(initialValue: Set(initialModels?.models.map(\.id) ?? []).subtracting(Set(existing.compactMap { $0.executionObject["id"]?.executionString })))
    }
    private var identityMatches: Bool { origin == [model.machineID, model.currentDeviceId ?? "unpaired"] }
    private var known: Set<String> { Set(existing.compactMap { $0.executionObject["id"]?.executionString }) }
    var body: some View {
        List {
            Section("连接服务") {
                Text(settingsNs).font(.caption.monospaced()).textSelection(.enabled)
                if let url = request["baseURL"]?.executionString { Text(url).font(.caption).textSelection(.enabled) }
                if let api = request["api"]?.executionString { Text("协议：\(api)").font(.caption).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 8) {
                    Text("临时密钥（可选）").font(.caption).foregroundStyle(.secondary)
                    SecureField("留空使用电脑当前凭据", text: $temporaryKey).textInputAutocapitalization(.never).autocorrectionDisabled().frame(minHeight: 44)
                }.disabled(busy)
                Text("临时密钥仅用于此次发现，不保存到电脑凭据或手机草稿。").font(.caption).foregroundStyle(.secondary)
                Button("发现可用模型") { discover() }.disabled(busy || !identityMatches || model.connectionState != .connected)
                if busy { ProgressView("电脑正在读取模型目录…") }
                if let error { Text(error).foregroundStyle(.red) }
                if !identityMatches { Text("电脑或配对身份已切换，请关闭后重新打开。").foregroundStyle(.red) }
            }
            if let result {
                Section("模型 · \(result.models.count)") {
                    if result.models.isEmpty { Text("服务没有返回可用模型，请检查地址与凭据。").foregroundStyle(.secondary) }
                    ForEach(Array(result.models.enumerated()).filter { search.isEmpty || $0.element.id.localizedCaseInsensitiveContains(search) || $0.element.name?.localizedCaseInsensitiveContains(search) == true }, id: \.offset) { _, item in
                        if known.contains(item.id) { row(item) }
                        else {
                            Button {
                                if !selected.insert(item.id).inserted { selected.remove(item.id) }
                            } label: { row(item) }
                                .buttonStyle(.plain).disabled(busy || !identityMatches)
                                .accessibilityAddTraits(selected.contains(item.id) ? [.isSelected] : [])
                        }
                    }
                }
                Section {
                    Button("将 \(selected.count) 个模型加入草稿") { onImport(result, selected); dismiss() }
                        .disabled(selected.isEmpty || busy || !identityMatches || model.connectionState != .connected)
                }
            }
        }
        .searchable(text: $search, prompt: "搜索发现的模型")
        .navigationTitle("发现模型").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        .onAppear { if origin == nil { origin = [model.machineID, model.currentDeviceId ?? "unpaired"] } }
        .onDisappear { query?.cancel(); query = nil; temporaryKey = "" }
    }
    private func row(_ item: DSHDiscoveredModels.Model) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: known.contains(item.id) ? "checkmark.circle.fill" : selected.contains(item.id) ? "checkmark.circle" : "circle")
                .foregroundStyle(selected.contains(item.id) ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name ?? item.id).font(.headline).foregroundStyle(.primary)
                Text(item.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let context = item.contextWindow { Text("上下文：\(context.formatted()) token").font(.caption).foregroundStyle(.secondary) }
                if let output = item.maxTokens { Text("最大输出：\(output.formatted()) token").font(.caption).foregroundStyle(.secondary) }
                if known.contains(item.id) { Text("已在草稿中，保留原有设置").font(.caption).foregroundStyle(.secondary) }
            }.fixedSize(horizontal: false, vertical: true)
        }.frame(minHeight: 44)
    }
    private func discover() {
        guard !busy, identityMatches else { return }
        busy = true; error = nil; result = nil; selected = []
        var probe = request
        if !temporaryKey.isEmpty { probe["apiKey"] = .string(temporaryKey) }
        query = Task {
            defer { busy = false; temporaryKey = "" }
            do {
                let found = try await model.discoverModels(settingsNs: settingsNs, request: probe)
                try Task.checkCancellation()
                guard identityMatches else { return }
                result = found
                selected = Set(found.models.map(\.id)).subtracting(known)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

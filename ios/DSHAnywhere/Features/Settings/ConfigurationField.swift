import SwiftUI

struct DSHConfigurationField: View {
    let path: [String]
    let schema: DSHConfigurationSchema
    let node: [String: DSHJSONValue]
    @Binding var draft: DSHConfigurationDraft
    let writable: Bool
    let arrayRoot: [String]?
    var isRoot = false
    @State private var newKey = ""
    @State private var jsonError: String?
    @State private var removingPath: [String]?
    private var current: DSHJSONValue? {
        if let value = draft.value.configurationValue(at: path) { return value }
        if draft.edits.contains(where: { $0.op == "unset" && path.starts(with: $0.path) }) { return draft.base.base?.configurationValue(at: path) ?? meta["default"] }
        return nil
    }
    private var kind: String { node["type"]?.executionString ?? "unknown" }
    private var meta: [String: DSHJSONValue] { node["meta"]?.executionObject ?? [:] }
    private var identity: String { DSHJSONValue.array(path.map(DSHJSONValue.string)).executionPrettyJSON }
    private var secret: Bool { meta["role"] == .string("secret") || draft.base.secrets.contains { $0.path == path } }
    private var hiddenArray: Bool { draft.base.secrets.contains { $0.set && $0.path.starts(with: path) && $0.path.count > path.count } }
    private var label: String {
        let key = path.last ?? "配置"
        let names = ["baseURL": "服务地址", "apiKeyEnv": "凭据引用", "models": "模型列表", "name": "名称", "displayName": "显示名称", "id": "模型 ID", "contextWindow": "上下文容量", "maxTokens": "最大输出 Token", "enabled": "启用", "thinking": "思考模式", "reasoningEffort": "思考强度", "provider": "服务商", "api": "协议"]
        return names[key].map { "\($0) · \(key)" } ?? key
    }
    var body: some View {
        content()
            .buttonStyle(.borderless)
            .fixedSize(horizontal: false, vertical: true)
            .confirmationDialog("从配置中移除此项？保存后才会写入电脑。", isPresented: Binding(get: { removingPath != nil }, set: { if !$0 { removingPath = nil } }), titleVisibility: .visible) {
                Button("移除此项", role: .destructive) { if let removingPath { draft.edit(path: removingPath, value: nil, arrayRoot: arrayRoot ?? (kind == "array" ? path : nil)) }; removingPath = nil }
            }
    }
    private func content() -> AnyView {
        if secret {
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                Text(label).font(.subheadline.weight(.medium))
                Text(draft.base.secrets.first { $0.path == path }?.set == true ? "电脑已配置，原值不会返回手机。" : "尚未配置").font(.caption).foregroundStyle(.secondary)
                if writable {
                    SecureField("输入新值以替换", text: Binding(get: { current?.executionString ?? "" }, set: { draft.edit(path: path, value: .string($0), arrayRoot: arrayRoot) })).textInputAutocapitalization(.never).autocorrectionDisabled()
                    resetButton
                }
            })
        }
        if path.count < 20, kind == "object" || kind == "dict" {
            let known = node["dict"]?.executionObject ?? [:]
            let keys = Array(Set(known.keys).union(current?.executionObject.keys.map { $0 } ?? [])).sorted()
            let children = AnyView(VStack(alignment: .leading, spacing: 18) {
                ForEach(keys, id: \.self) { key in
                    child(path + [key], node: schema.node(kind == "dict" ? node["inner"] : known[key]), arrayRoot: arrayRoot)
                    if kind == "dict", writable { Button("清除 \(key) 的用户配置", role: .destructive) { removingPath = path + [key] }.font(.caption) }
                }
                if kind == "dict", writable {
                    TextField("新项目名称", text: $newKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("添加项目") {
                        let inner = schema.node(node["inner"])
                        draft.edit(path: path + [newKey], value: seed(inner), arrayRoot: arrayRoot); newKey = ""
                    }.disabled(newKey.isEmpty || newKey.contains("\0") || keys.contains(newKey))
                }
            }.padding(.vertical, 6))
            if path.isEmpty || isRoot { return children }
            return AnyView(DisclosureGroup(label) { children; if writable { resetButton } })
        }
        if path.count < 20, kind == "array" {
            let values = current?.executionArray ?? []
            let canEdit = writable && !hiddenArray
            return AnyView(DisclosureGroup("\(label) · \(values.count)") {
                if hiddenArray { Text("此数组包含电脑端隐藏密钥。为保留原值，请在电脑端编辑。").font(.caption).foregroundStyle(.secondary) }
                ForEach(values.indices, id: \.self) { index in
                    DisclosureGroup(values[index].executionObject["name"]?.executionString ?? values[index].executionObject["id"]?.executionString ?? "项目 \(index + 1)") {
                        child(path + [String(index)], node: schema.node(node["inner"]), arrayRoot: arrayRoot ?? path, writable: canEdit)
                        if canEdit {
                            HStack {
                                Button("上移") { var changed = values; changed.swapAt(index, index - 1); draft.edit(path: path, value: .array(changed), arrayRoot: arrayRoot) }.disabled(index == 0)
                                Button("下移") { var changed = values; changed.swapAt(index, index + 1); draft.edit(path: path, value: .array(changed), arrayRoot: arrayRoot) }.disabled(index == values.count - 1)
                            }.frame(minHeight: 44)
                            Button("移除此项目", role: .destructive) { removingPath = path + [String(index)] }
                        }
                    }
                }
                if canEdit {
                    Button("添加项目") { draft.edit(path: path, value: .array(values + [seed(schema.node(node["inner"]))]), arrayRoot: arrayRoot) }
                    resetButton
                }
            })
        }
        return AnyView(VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.subheadline.weight(.medium))
            if let description = descriptionText { Text(description).font(.caption).foregroundStyle(.secondary) }
            if !writable { Text(current?.executionPrettyJSON ?? "未设置").font(.subheadline).textSelection(.enabled) }
            else if let options = schema.choices(node) {
                Picker(label, selection: Binding(get: { current?.executionPrettyJSON ?? "__unset__" }, set: { selected in
                    draft.edit(path: path, value: options.first { $0.executionPrettyJSON == selected }, arrayRoot: arrayRoot)
                })) {
                    Text("未设置").tag("__unset__")
                    ForEach(Array(options.enumerated()), id: \.offset) { _, value in Text(value.executionString ?? value.executionPrettyJSON).tag(value.executionPrettyJSON) }
                }.pickerStyle(.menu).labelsHidden()
            } else if kind == "boolean" {
                Toggle("启用", isOn: Binding(get: { current == .bool(true) }, set: { draft.edit(path: path, value: .bool($0), arrayRoot: arrayRoot) }))
            } else if kind == "number" {
                TextField("未设置", text: Binding(get: { draft.rawNumbers[identity] ?? current?.executionNumber.map { numberText($0) } ?? "" }, set: { editNumber($0) }))
                    .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                if draft.invalidNumbers.contains(identity) { Text("请输入有效数字，并遵守字段的最小值、最大值和整数要求。").font(.caption).foregroundStyle(.red) }
            } else if kind == "string" {
                TextField("未设置", text: Binding(get: { current?.executionString ?? "" }, set: { draft.edit(path: path, value: .string($0), arrayRoot: arrayRoot) }), axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(1...6)
                if meta["role"] == .string("credential-ref"), let ref = current?.executionString, !ref.isEmpty {
                    NavigationLink("管理此凭据") { DSHCredentialEditor(initialRef: ref) }
                }
            } else {
                DisclosureGroup("高级 JSON 编辑") {
                    Text("保留原生字段；解析并应用后才参与保存。").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { draft.rawJSON[identity] ?? current?.executionPrettyJSON ?? "null" }, set: { draft.rawJSON[identity] = $0; draft.unappliedJSON.insert(identity) }))
                        .font(.caption.monospaced()).frame(minHeight: 150)
                    Button("解析并应用 JSON") {
                        do {
                            let value = try JSONDecoder().decode(DSHJSONValue.self, from: Data((draft.rawJSON[identity] ?? current?.executionPrettyJSON ?? "null").utf8))
                            draft.edit(path: path, value: value, arrayRoot: arrayRoot); draft.unappliedJSON.remove(identity); jsonError = nil
                        } catch { jsonError = "JSON 格式无效，当前输入已保留。" }
                    }
                    if let jsonError { Text(jsonError).font(.caption).foregroundStyle(.red) }
                }
            }
            if writable { resetButton }
        })
    }
    private var descriptionText: String? {
        let text = meta["description"]
        return text?.executionString ?? text?.executionObject["zh-CN"]?.executionString ?? text?.executionObject["zh"]?.executionString ?? text?.executionObject[""]?.executionString
    }
    private var resetButton: some View {
        Button("恢复此项基础值") { draft.edit(path: path, value: nil, arrayRoot: arrayRoot); draft.rawNumbers.removeValue(forKey: identity); draft.invalidNumbers.remove(identity); draft.rawJSON.removeValue(forKey: identity); draft.unappliedJSON.remove(identity) }.font(.caption).frame(minHeight: 44, alignment: .leading)
    }
    private func child(_ path: [String], node: [String: DSHJSONValue], arrayRoot: [String]?, writable: Bool? = nil) -> DSHConfigurationField {
        .init(path: path, schema: schema, node: node, draft: $draft, writable: writable ?? self.writable, arrayRoot: arrayRoot)
    }
    private func seed(_ node: [String: DSHJSONValue]) -> DSHJSONValue {
        if let value = node["meta"]?.executionObject["default"] { return value }
        switch node["type"]?.executionString { case "object", "dict": return .object([:]); case "array": return .array([]); case "boolean": return .bool(false); case "number": return .number(0); case "const": return node["value"] ?? .null; default: return .string("") }
    }
    private func numberText(_ value: Double) -> String { value.isFinite && abs(value) < 9_007_199_254_740_991 && value.rounded() == value ? String(Int64(value)) : String(value) }
    private func editNumber(_ text: String) {
        draft.rawNumbers[identity] = text
        if text.isEmpty { draft.invalidNumbers.remove(identity); draft.edit(path: path, value: nil, arrayRoot: arrayRoot); return }
        guard let value = Double(text), value.isFinite,
              meta["min"]?.executionNumber.map({ value >= $0 }) ?? true,
              meta["max"]?.executionNumber.map({ value <= $0 }) ?? true,
              meta["step"] != .number(1) || value.rounded() == value else { draft.invalidNumbers.insert(identity); return }
        draft.invalidNumbers.remove(identity); draft.edit(path: path, value: .number(value), arrayRoot: arrayRoot)
    }
}

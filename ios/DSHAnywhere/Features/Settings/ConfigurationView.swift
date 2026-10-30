import SwiftUI

struct DSHComputerConfigurationView: View {
    @EnvironmentObject private var model: DSHAppModel
    @State private var settings: DSHSettingsSnapshot?
    @State private var plugins: DSHPluginInventory?
    @State private var providers: DSHProviderDirectory?
    @State private var errors: [String: String] = [:]
    @State private var loading = false
    @State private var readEpoch = UUID()
    @State private var search = ""
    @State private var loadedIdentity: [String]?
    var body: some View {
        List {
            Section {
                Text(model.machineName).font(.headline)
                if model.connectionState != .connected { Text("电脑离线；可阅读本次已加载的配置，连接后才能保存。").font(.caption).foregroundStyle(.secondary) }
                if loading { ProgressView("读取电脑配置…") }
                Button("刷新电脑配置") { Task { await load() } }.disabled(loading || model.connectionState != .connected)
                ForEach(errors.keys.sorted(), id: \.self) { key in Text("\(key)：\(errors[key] ?? "")").font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            if let settings {
                if !settings.writable { Text("当前配置来源只读。").foregroundStyle(.secondary) }
                if let providers {
                    Section("模型服务") {
                        ForEach(providers.configurable.filter { matches($0.displayName + $0.provider) }) { provider in
                            if let namespace = settings.namespaces.first(where: { $0.ns == provider.settingsNs }) {
                                NavigationLink {
                                    DSHSettingsEditor(namespace: namespace, writable: settings.writable, rootPath: provider.settingsPath, title: provider.displayName, provider: provider.provider, onSaved: replace)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(provider.displayName).font(.headline)
                                        Text("\(provider.provider) · \(providers.registered.contains { $0.id == provider.provider } ? "已激活" : provider.declared == false ? "可配置，尚未添加" : "已声明，尚未激活")").font(.caption).foregroundStyle(.secondary)
                                        if let error = provider.error { Text(error).font(.caption).foregroundStyle(.red) }
                                    }.fixedSize(horizontal: false, vertical: true)
                                }
                            } else { Text("\(provider.displayName) · 配置来源暂不可用").foregroundStyle(.secondary) }
                        }
                        ForEach(providers.registered.filter { item in !providers.configurable.contains { $0.provider == item.id } && matches(item.name + item.id) }, id: \.id) { item in
                            VStack(alignment: .leading) { Text(item.name); Text("\(item.id) · 由电脑端插件管理，未声明配置表单").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section("全部配置") {
                    ForEach(settings.namespaces.filter { matches($0.ns) }) { namespace in
                        NavigationLink { DSHSettingsEditor(namespace: namespace, writable: settings.writable, onSaved: replace) } label: {
                            VStack(alignment: .leading, spacing: 4) { Text(namespace.ns); Text(namespace.applies == "restart" ? "保存后需要重启电脑端 Harness" : "保存后即时应用").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section("凭据") { NavigationLink("管理凭据引用") { DSHCredentialEditor(initialRef: "") } }
            }
            if let plugins {
                Section("电脑端插件 · \(plugins.entries.count)") {
                    ForEach(plugins.entries.filter { matches($0.moduleName) }) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.moduleName).font(.subheadline.weight(.medium)).textSelection(.enabled)
                            Text("\(entry.enabled ? "已启用" : "未启用") · \(phase(entry.fiberPhase))").font(.caption).foregroundStyle(.secondary)
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(plugins.agentPresets ?? []) { preset in
                    Section("\(preset.name ?? preset.id)\(preset.isDefault ? " · 默认模式" : "")") {
                        Text("模式预设").font(.caption).foregroundStyle(.secondary)
                        if let broken = preset.broken { Text(broken).foregroundStyle(.red).textSelection(.enabled) }
                        ForEach(Array(preset.rows.enumerated()).filter { matches($0.element.moduleName) }, id: \.offset) { _, row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.moduleName).font(.subheadline).textSelection(.enabled)
                                Text(row.enabled == .string("conditional") ? "按条件启用 · \(phase(row.fiberPhase))" : "\(row.enabled == .bool(true) ? "已启用" : "未启用") · \(phase(row.fiberPhase))").font(.caption).foregroundStyle(.secondary)
                                if let condition = row.condition { Text(condition).font(.caption.monospaced()).textSelection(.enabled) }
                            }.fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "搜索服务、配置或插件")
        .navigationTitle("电脑端配置").navigationBarTitleDisplayMode(.inline)
        .task(id: "\(model.machineID):\(model.currentDeviceId ?? "unpaired"):\(model.configurationChangeRevision):\(model.connectionState)") {
            readEpoch = UUID(); loading = false
            let identity = [model.machineID, model.currentDeviceId ?? "unpaired"]
            if loadedIdentity != identity { settings = nil; plugins = nil; providers = nil; errors = [:]; loadedIdentity = identity }
            do { try await Task.sleep(for: .milliseconds(180)); try Task.checkCancellation(); if model.connectionState == .connected { await load() } } catch {}
        }
        .refreshable { await load() }
    }
    private func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }
    private func phase(_ value: String?) -> String {
        switch value { case "active": "运行中"; case "failed": "加载失败"; case "pending": "等待加载"; case "loading": "正在加载"; case "unloading": "正在卸载"; case nil: "未运行"; default: value ?? "" }
    }
    private func replace(_ namespace: DSHSettingsNamespace) {
        guard let snapshot = settings else { return }
        settings = .init(writable: snapshot.writable, hasDocument: snapshot.hasDocument, namespaces: snapshot.namespaces.map { $0.ns == namespace.ns ? namespace : $0 })
    }
    private func load() async {
        guard !loading else { return }
        let token = readEpoch
        let machine = model.machineID, device = model.currentDeviceId
        loading = true; errors = [:]
        defer { if readEpoch == token { loading = false } }
        for section in ["settings", "providers", "plugins"] {
            do {
                let result = try await model.readConfiguration(section)
                try Task.checkCancellation()
                guard readEpoch == token, model.machineID == machine, model.currentDeviceId == device else { return }
                switch section {
                case "settings": settings = try result.decoded(DSHSettingsSnapshot.self)
                case "providers": providers = try result.decoded(DSHProviderDirectory.self)
                default: plugins = try result.decoded(DSHPluginInventory.self)
                }
            } catch is CancellationError { return }
            catch { if readEpoch == token { errors[section] = error.localizedDescription } }
        }
    }
}

struct DSHSettingsEditor: View {
    let namespace: DSHSettingsNamespace
    let writable: Bool
    var rootPath: [String] = []
    var title: String? = nil
    var provider: String? = nil
    var onSaved: (DSHSettingsNamespace) -> Void = { _ in }
    @EnvironmentObject private var model: DSHAppModel
    @State private var draft: DSHConfigurationDraft?
    @State private var latest: DSHSettingsNamespace?
    @State private var busy = false
    @State private var error: String?
    @State private var storageError: String?
    @State private var status: String?
    @State private var origin: [String]?
    @State private var loadedDraft = false
    @State private var storedToken: String?
    @State private var refreshNeeded = false
    @State private var refreshEpoch = UUID()
    @State private var refreshTask: Task<Void, Never>?
    var storage = DSHSecureConfigurationStorage()
    private var address: String { storage.key(machine: origin?.first ?? model.machineID, device: origin?.last ?? model.currentDeviceId ?? "unpaired", scope: "settings:\(namespace.ns):\(DSHJSONValue.array(rootPath.map(DSHJSONValue.string)).executionPrettyJSON)") }
    private var identityMatches: Bool { model.currentDeviceId != nil && origin == [model.machineID, model.currentDeviceId ?? ""] }
    @State private var showDiscovery = false
    var body: some View {
        List {
            if let draft {
                Section {
                    if !identityMatches { Text("电脑或配对身份已切换，请返回并重新打开配置。").foregroundStyle(.red) }
                    Text(draft.base.applies == "restart" ? "保存后需要重启电脑端 Harness 才会应用。" : "更改由电脑端 Harness 校验并应用。").font(.caption).foregroundStyle(.secondary)
                    Text("版本 \(draft.base.revision) · \(draft.edits.count) 处修改").font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if let storageError { Text(storageError).foregroundStyle(.red); if loadedDraft { Button("重试保存草稿") { persist() } } }
                    if let status { Text(status).foregroundStyle(.secondary) }
                    if draft.pending != nil, !busy { Text("上次保存结果尚未确认；原请求和输入已保存在本机安全存储中。").font(.caption).foregroundStyle(.secondary) }
                    Button("读取电脑最新版本") { Task { await refresh() } }.disabled(busy || !identityMatches || model.connectionState != .connected)
                    if let latest, latest != draft.base || draft.pending != nil {
                        Text("电脑当前版本 \(latest.revision)。保留修改会更新这些路径：\(draft.edits.map { $0.path.joined(separator: ".") }.joined(separator: "、"))").font(.caption)
                        DisclosureGroup("查看电脑上的当前值") { Text(latest.value.executionPrettyJSON).font(.caption.monospaced()).textSelection(.enabled) }
                        Button("已核对电脑状态，保留修改继续编辑") { self.draft?.merge(onto: latest); self.latest = nil; error = nil; persist() }.disabled(!identityMatches || busy)
                    }
                }
                if let modelPath = modelsPath(draft) {
                    Section("模型目录") {
                        Button("从服务发现模型") { showDiscovery = true }
                            .disabled(!identityMatches || !loadedDraft || busy || draft.pending != nil || !writable || model.connectionState != .connected)
                        Text("使用当前表单中的服务设置；选中的新模型先加入草稿，保存后才写入电脑。").font(.caption).foregroundStyle(.secondary)
                    }
                    .sheet(isPresented: $showDiscovery) {
                        NavigationStack {
                            DSHModelDiscoveryView(settingsNs: namespace.ns, request: discoveryRequest(draft), existing: draft.value.configurationValue(at: modelPath)?.executionArray ?? []) { result, selected in
                                guard identityMatches, var current = self.draft, current.pending == nil else { return }
                                let values = current.value.configurationValue(at: modelPath)?.executionArray ?? []
                                current.edit(path: modelPath, value: .array(result.appending(to: values, selected: selected)), arrayRoot: DSHConfigurationSchema(document: current.base.schema).arrayRoot(in: modelPath) ?? modelPath)
                                self.draft = current
                            }.environmentObject(model)
                        }
                    }
                }
                Section {
                    DSHConfigurationField(path: rootPath, schema: .init(document: draft.base.schema), node: DSHConfigurationSchema(document: draft.base.schema).at(rootPath),
                        draft: Binding(get: { self.draft ?? draft }, set: { self.draft = $0 }), writable: writable && identityMatches && loadedDraft && !busy && draft.pending == nil,
                        arrayRoot: DSHConfigurationSchema(document: draft.base.schema).arrayRoot(in: rootPath), isRoot: true)
                }
                Section {
                    Button(draft.pending == nil ? "保存到电脑" : "使用原请求重试") { Task { await save() } }
                        .disabled(busy || !identityMatches || !loadedDraft || !writable || draft.edits.isEmpty || !draft.invalidNumbers.isEmpty || !draft.unappliedJSON.isEmpty || storageError != nil || (latest != nil && latest != draft.base && draft.pending == nil) || model.connectionState != .connected)
                    if busy { ProgressView("等待电脑确认…") }
                    DisclosureGroup("原生字段定义") { Text(draft.base.schema.executionPrettyJSON).font(.caption.monospaced()).textSelection(.enabled) }
                }
            } else { ProgressView("读取安全草稿…") }
        }
        .navigationTitle(title ?? namespace.ns).navigationBarTitleDisplayMode(.inline)
        .task(id: [model.machineID, model.currentDeviceId ?? "unpaired"]) {
            guard let device = model.currentDeviceId else { error = "请先完成电脑配对。"; return }
            if origin == nil { origin = [model.machineID, device] }
            guard identityMatches else { return }
            do { let record = try storage.loadRecord(DSHConfigurationDraft.self, key: address); storedToken = record.token; let restored = record.value ?? .init(base: namespace); loadedDraft = true; draft = restored; if draft?.base != namespace { latest = namespace } }
            catch { storageError = "安全草稿暂不可读，请检查本机钥匙串后重新打开。"; draft = .init(base: namespace) }
        }
        .onChange(of: draft) { _, _ in persist() }
        .onChange(of: model.configurationChangeRevision) { _, _ in refreshAfterChange() }
        .onChange(of: model.connectionState) { _, next in if next == .connected { refreshAfterChange() } }
        .onChange(of: busy) { _, next in if !next, refreshNeeded { refreshAfterChange() } }
        .onDisappear { refreshTask?.cancel(); refreshTask = nil; refreshEpoch = UUID() }

    }
    private func modelsPath(_ draft: DSHConfigurationDraft) -> [String]? {
        let path = rootPath + ["models"]
        let schema = DSHConfigurationSchema(document: draft.base.schema)
        guard schema.at(path)["type"] == .string("array"), !draft.base.secrets.contains(where: { $0.set && $0.path.starts(with: path) }) else { return nil }
        return path
    }
    private func discoveryRequest(_ draft: DSHConfigurationDraft) -> [String: DSHJSONValue] {
        var result: [String: DSHJSONValue] = [:]
        if let provider { result["provider"] = .string(provider) }
        for field in ["baseURL", "api", "apiKey"] {
            if let value = draft.value.configurationValue(at: rootPath + [field])?.executionString, !value.isEmpty { result[field] = .string(value) }
        }
        return result
    }
    private func refreshAfterChange() {
        guard loadedDraft, identityMatches else { return }
        refreshNeeded = true
        guard !busy, model.connectionState == .connected else { return }
        refreshNeeded = false
        refreshTask?.cancel()
        refreshTask = Task {
            do { try await Task.sleep(for: .milliseconds(180)); try Task.checkCancellation() } catch { return }
            if busy { refreshNeeded = true; return }
            await refresh()
        }
    }
    private func persist() {
        guard loadedDraft, let draft else { return }
        do { storedToken = try storage.save(draft, key: address, expecting: storedToken); storageError = nil }
        catch { storageError = error is DSHConfigurationDraftChanged ? error.localizedDescription : "草稿未能写入本机安全存储，暂不能发送；当前输入仍保留在页面中。" }
    }
    private func refresh() async {
        guard identityMatches else { return }
        let token = UUID(); refreshEpoch = token
        do {
            let snapshot = try await model.readConfiguration("settings").decoded(DSHSettingsSnapshot.self)
            try Task.checkCancellation()
            guard identityMatches, refreshEpoch == token else { return }
            latest = snapshot.namespaces.first { $0.ns == namespace.ns }
            if latest == nil { self.error = "此配置项目已从电脑端移除。草稿仍保留，请返回配置目录。" }
        } catch { if identityMatches, refreshEpoch == token { self.error = error.localizedDescription } }
    }
    private func save() async {
        guard var value = draft, identityMatches, loadedDraft, !busy else { return }
        busy = true; error = nil; status = nil
        defer { busy = false }
        if value.pending?.payload != value.payload { value.pending = model.configurationCommand(payload: value.payload) }
        draft = value; persist()
        guard storageError == nil, let command = value.pending else { return }
        do {
            let receipt = try await model.updateConfiguration(command)
            guard let saved = receipt.namespace else { throw DSHConfigurationRequestError(failure: .init(code: "invalid-configuration-receipt", message: "未收到完整配置回执。")) }
            draft = .init(base: saved); latest = nil
            status = saved.applies == "restart" ? "已保存，重启电脑端 Harness 后生效。" : "已保存到电脑。"
            if identityMatches { onSaved(saved) }; persist()
        } catch {
            if (error as? DSHConfigurationRequestError)?.definitelyNotCommitted == true || error is any DSHCommandNotSentError { draft?.pending = nil }
            self.error = error.localizedDescription; persist(); await refresh()
        }
    }
}

struct DSHCredentialEditor: View {
    let initialRef: String
    @EnvironmentObject private var model: DSHAppModel
    @State private var ref = ""
    @State private var secret = ""
    @State private var info: DSHCredentialInfo?
    @State private var pending: DSHCommand?
    @State private var busy = false
    @State private var error: String?
    @State private var storageReady = false
    @State private var notice: String?
    @State private var confirmUnset = false
    @State private var origin: [String]?
    @State private var loadedDraft = false
    @State private var storedToken: String?
    @State private var refreshNeeded = false
    @State private var refreshEpoch = UUID()
    @State private var refreshTask: Task<Void, Never>?
    var storage = DSHSecureConfigurationStorage()
    private struct Draft: Codable { var ref: String; var value: String; var pending: DSHCommand? }
    private var address: String { storage.key(machine: origin?.first ?? model.machineID, device: origin?.last ?? model.currentDeviceId ?? "unpaired", scope: "credential:\(initialRef)") }
    private var identityMatches: Bool { model.currentDeviceId != nil && origin == [model.machineID, model.currentDeviceId ?? ""] }
    var body: some View {
        Form {
            Section("凭据引用") {
                if !identityMatches { Text("电脑或配对身份已切换，请返回并重新打开凭据。").foregroundStyle(.red) }
                TextField("例如 DEEPSEEK_API_KEY", text: Binding(get: { ref }, set: { ref = $0; secret = ""; info = nil; persist() })).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(busy || pending != nil)
                Button("读取凭据状态") { Task { await refresh() } }.disabled(busy || !validRef || model.connectionState != .connected)
                if let info {
                    Text(info.configured ? "已配置；密钥不会返回手机。" : "尚未配置").font(.subheadline)
                    if let source = info.source { Text("来源：\(source)").font(.caption).foregroundStyle(.secondary) }
                    if !info.writable { Text("此来源只读，请在电脑端处理。").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("写入电脑") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("新的密钥").font(.caption).foregroundStyle(.secondary)
                    SecureField("输入新的密钥", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(busy || pending != nil).frame(minHeight: 44)
                }
                Button(pending == nil ? "保存密钥" : "使用原请求重试") { Task { await write(action: pending?.payload.executionObject["action"]?.executionString ?? "set") } }
                    .disabled(busy || info?.writable != true || !validRef || !storageReady || (secret.isEmpty && pending == nil) || model.connectionState != .connected)
                if info?.configured == true { Button("移除此凭据", role: .destructive) { confirmUnset = true }.disabled(busy || pending != nil || info?.writable != true || !storageReady) }
                if busy { ProgressView("等待电脑确认…") }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if !storageReady, loadedDraft { Button("重试安全草稿保存") { storageReady = true; persist() } }
                if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                if pending != nil { Text("结果未确认时会保留同一个请求。请先读取电脑状态，再决定是否重新输入。").font(.caption).foregroundStyle(.secondary)
                    Button("已检查电脑状态，重新输入密钥") { pending = nil; secret = ""; notice = nil; persist() }.disabled(busy || info == nil)
                }
            }
        }
        .navigationTitle("管理凭据").navigationBarTitleDisplayMode(.inline)
        .disabled(!identityMatches)
        .task(id: [model.machineID, model.currentDeviceId ?? "unpaired"]) {
            guard let device = model.currentDeviceId else { error = "请先完成电脑配对。"; return }
            if origin == nil { origin = [model.machineID, device] }
            guard identityMatches else { return }
            do { let record = try storage.loadRecord(Draft.self, key: address); storedToken = record.token; let draft = record.value; ref = draft?.ref ?? initialRef; secret = draft?.value ?? ""; pending = draft?.pending; loadedDraft = true; storageReady = true; if validRef { await refresh() } }
            catch { self.error = "安全草稿读取失败，请检查本机钥匙串后重新打开。" }
        }
        .onChange(of: secret) { _, _ in persist() }
        .onChange(of: model.configurationChangeRevision) { _, _ in refreshAfterChange() }
        .onChange(of: model.connectionState) { _, next in if next == .connected { refreshAfterChange() } }
        .onChange(of: busy) { _, next in if !next, refreshNeeded { refreshAfterChange() } }
        .onDisappear { refreshTask?.cancel(); refreshTask = nil; refreshEpoch = UUID() }

        .confirmationDialog("从电脑端移除此凭据？引用它的模型服务可能暂时无法调用。", isPresented: $confirmUnset, titleVisibility: .visible) { Button("移除凭据", role: .destructive) { Task { await write(action: "unset") } } }
    }
    private func refreshAfterChange() {
        guard loadedDraft, identityMatches, validRef else { return }
        refreshNeeded = true
        guard !busy, model.connectionState == .connected else { return }
        refreshNeeded = false
        refreshTask?.cancel()
        refreshTask = Task {
            do { try await Task.sleep(for: .milliseconds(180)); try Task.checkCancellation() } catch { return }
            if busy { refreshNeeded = true; return }
            await refresh()
        }
    }
    private var validRef: Bool { ref.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil && ref.utf8.count <= 256 }
    private func persist() {
        guard storageReady, loadedDraft else { return }
        do { storedToken = try storage.save(Draft(ref: ref, value: secret, pending: pending), key: address, expecting: storedToken) }
        catch { storageReady = false; self.error = error is DSHConfigurationDraftChanged ? error.localizedDescription : "安全草稿保存失败，暂不能发送；输入仍在页面中。" }
    }
    private func refresh() async {
        guard identityMatches, validRef else { return }
        let requested = ref, token = UUID(); refreshEpoch = token
        do {
            let result = try await model.readConfiguration("credentials", refs: [requested])
            try Task.checkCancellation()
            if identityMatches, ref == requested, refreshEpoch == token { info = try result.decoded([String: DSHCredentialInfo].self)[requested] }
        } catch { if identityMatches, refreshEpoch == token { self.error = error.localizedDescription } }
    }
    private func write(action: String) async {
        guard identityMatches, !busy, storageReady else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        if pending == nil {
            var payload: [String: DSHJSONValue] = ["kind": .string("credential"), "action": .string(action), "ref": .string(ref)]
            if action == "set" { payload["value"] = .string(secret) }
            pending = model.configurationCommand(payload: .object(payload)); persist()
        }
        guard storageReady, let pending else { return }
        info = nil
        do { _ = try await model.updateConfiguration(pending); self.pending = nil; secret = ""; persist(); notice = action == "set" ? "电脑已确认保存密钥。" : "电脑已确认移除凭据。"; await refresh() }
        catch {
            if (error as? DSHConfigurationRequestError)?.definitelyNotCommitted == true || error is any DSHCommandNotSentError { self.pending = nil }
            self.error = error.localizedDescription; persist(); await refresh()
        }
    }
}

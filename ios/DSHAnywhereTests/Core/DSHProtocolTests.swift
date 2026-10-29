import XCTest
@testable import DSHAnywhere
#if canImport(UIKit)
import UIKit
import SwiftUI
@MainActor
private final class DSHModelPanelFixture: ObservableObject {
    @Published var selection = DSHModelSelection(provider: "test", model: "muse", reasoningEffort: "xhigh")
    @Published var presented = false
    @Published var showsModels = false
    let catalog = DSHModelCatalog(
        default: DSHModelSelection(provider: "test", model: "muse", reasoningEffort: "xhigh"),
        routableProviders: ["test"],
        groups: [DSHModelCatalogGroup(id: "test", name: "Test models", models: [
            DSHModelCatalogModel(id: "muse", name: "muse-spark-1.3-contributor", reasoning: DSHModelReasoning(
                efforts: ["minimal", "low", "medium", "high", "xhigh"].map {
                    DSHModelReasoningEffort(id: $0, name: $0.capitalized)
                }, defaultEffort: "high")),
            DSHModelCatalogModel(id: "short", name: "Three-level model", reasoning: DSHModelReasoning(
                efforts: ["low", "medium", "high"].map {
                    DSHModelReasoningEffort(id: $0, name: $0.capitalized)
                }, defaultEffort: "medium")),
            DSHModelCatalogModel(id: "plain", name: "No reasoning model")
        ])], failures: [])
}

private func dshConfigurationLayoutNamespace() throws -> DSHJSONValue {
    try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"ns":"llm-layout","revision":4,"applies":"live","value":{"baseURL":"https://api.example.test/compatible/v1","apiKeyEnv":"DEEPSEEK_API_KEY","maxTokens":8192,"enabled":true,"models":[{"id":"reasoner","name":"思考模型","contextWindow":131072,"futureField":true}],"reasoningEffort":"high"},"base":{"baseURL":"https://api.example.test/v1"},"user":{"baseURL":"https://api.example.test/compatible/v1"},"secrets":[{"path":["apiKey"],"set":true}],"schema":{"uid":1,"refs":{"1":{"type":"object","dict":{"baseURL":2,"apiKeyEnv":3,"maxTokens":4,"models":5,"enabled":7,"reasoningEffort":8,"apiKey":11}},"2":{"type":"string","meta":{"description":"服务地址由电脑端校验，未修改的字段会保留。"}},"3":{"type":"string","meta":{"role":"credential-ref"}},"4":{"type":"number","meta":{"min":1,"step":1}},"5":{"type":"array","inner":6},"6":{"type":"object","dict":{"id":2,"name":2,"contextWindow":4}},"7":{"type":"boolean"},"8":{"type":"union","list":[9,10]},"9":{"type":"const","value":"high"},"10":{"type":"const","value":"max"},"11":{"type":"string","meta":{"role":"secret"}}}}}"#.utf8))
}
private actor DSHFileLayoutTransport: DSHAppTransport {
    private var fileData: Data?
    func setFileData(_ data: Data) { fileData = data }
    func seedMediaQueue(_ queue: DSHServerQueue) throws {
        emit(type: "queue.changed", id: "media-queue", payload: try JSONDecoder().decode(DSHJSONValue.self, from: JSONEncoder().encode(queue)))
    }
    private var continuation: AsyncThrowingStream<DSHEvent, Error>.Continuation?
    private var sequence: Int64 = 0
    func pair(serverAddress: String, machineId: String, credential: DSHPairingCredential, deviceName: String) async throws -> DSHRemoteProfile { throw DSHWebSocketError.notConnected }
    func connect() async -> AsyncThrowingStream<DSHEvent, Error> {
        let stream = AsyncThrowingStream<DSHEvent, Error>.makeStream(); continuation = stream.continuation
        emit(type: "connection.ready", id: "ready", payload: .object([:])); return stream.stream
    }
    func setIncludeArchived(_ value: Bool) async { }
    func send(_ command: DSHCommand) async throws {
        if command.type == "configuration.read" {
            let section = command.payload.executionObject["section"]?.executionString ?? "settings"
            let value: DSHJSONValue
            switch section {
            case "settings": value = .object(["writable": .bool(true), "hasDocument": .bool(true), "namespaces": .array([try dshConfigurationLayoutNamespace()])])
            case "providers": value = try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"registered":[{"id":"deepseek","name":"DeepSeek"}],"configurable":[{"provider":"deepseek","displayName":"DeepSeek 思考模型","settingsNs":"llm-layout","settingsPath":[]},{"provider":"custom","displayName":"自定义服务","settingsNs":"llm-layout","settingsPath":[],"declared":true,"error":"等待检查服务地址与凭据来源"}]}"#.utf8))
            case "plugins": value = try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"entries":[{"entryId":"a","moduleName":"@deepseek-ai/dsh-schedule","enabled":true,"fiberPhase":"active"},{"entryId":"b","moduleName":"本机可选插件与较长名称的加载状态示例","enabled":false,"fiberPhase":"failed"}],"agentPresets":[{"id":"standard","name":"标准模式","trust":"system","isDefault":true,"rows":[{"entryId":null,"moduleName":"按工作区启用的插件","enabled":"conditional","condition":"workspace is available","fiberPhase":null}]}]}"#.utf8))
            default:
                let refs = command.payload.executionObject["refs"]?.executionArray.compactMap(\.executionString) ?? []
                value = .object(Dictionary(uniqueKeysWithValues: refs.map { ($0, .object(["configured": .bool(true), "writable": .bool(true), "source": .string("本机凭据存储")])) }))
            }
            emit(type: "configuration.result", id: command.requestId, payload: .object(["section": .string(section), "value": value]))
        } else if command.type == "schedule.get" {
            let payload = try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"sessionId":"s","epoch":"schedule-preview","seq":100,"available":true,"supported":true,"items":[{"id":"once","kind":"at","prompt":"检查手机端长对话的搜索定位和历史加载，记录实际发现的问题。","scheduledAt":"2026-10-28T08:00:00.000Z"},{"id":"recurring","kind":"every","prompt":"检查桌面端的构建结果，并在原会话继续处理失败原因。","everySeconds":1800,"scheduledAt":"2026-10-30T01:00:00.000Z"}]}"#.utf8))
            emit(type: "schedule.projection", id: command.requestId, payload: payload, sessionID: command.sessionId)
        } else if command.type == "session.search" || command.type == "conversation.search" {
            var payload: [String: DSHJSONValue] = ["query": command.payload.executionObject["query"] ?? .string(""), "hasMore": .bool(true), "nextCursor": .string("next-native-page"), "items": .array([
                .object(["sessionId": .string("s"), "nativeSequence": .number(42), "type": .string("assistant/message"), "time": .number(1793274000000), "surface": .string("current"),
                    "snippet": .string("手机需要保留桌面端的计划、目标、思考过程和工具结果。点击搜索结果后，按原生消息位置读取完整记录。"),
                    "session": .object(["id": .string("s"), "title": .string("DeepSeek Harness 信息展示与手机阅读适配"), "updatedAt": .number(1793274000000)])]),
                .object(["sessionId": .string("other"), "nativeSequence": .number(0), "type": .string("user/message"), "time": .number(1793187600000), "surface": .string("shadowed"),
                    "snippet": .string("检查长对话的历史分页，避免把未加载的中间记录显示为完整历史。"),
                    "session": .object(["id": .string("other"), "title": .string("历史加载和准确定位"), "updatedAt": .number(1793187600000)])])])]
            if let session = command.sessionId { payload["scopeSessionId"] = .string(session) }
            emit(type: "search.results", id: command.requestId, payload: .object(payload), sessionID: command.sessionId)
        } else if command.type == "workspace.files" {
            emit(type: command.type, id: command.requestId, payload: .object(["sessionId": .string("s"), "path": .string(""), "truncated": .bool(true), "entries": .array([
                .object(["name": .string("设计资源"), "type": .string("directory")]),
                .object(["name": .string("交付说明与跨端验证记录-2026-10-29.md"), "type": .string("file"), "size": .number(16384)]),
                .object(["name": .string("演示视频.mp4"), "type": .string("file"), "size": .number(12 * 1024 * 1024)]),
                .object(["name": .string("界面截图.png"), "type": .string("file"), "size": .number(25731)])])]))
        } else if command.type == "reference.list" {
            let kind = command.payload.executionObject["kind"]?.executionString ?? "file", query = command.payload.executionObject["query"]?.executionString ?? ""
            let items: [DSHJSONValue] = kind == "file" ? [
                .object(["id": .string("dir"), "kind": .string("directory"), "label": .string("手机阅读与跨端验证资源目录"), "path": .string("手机阅读与跨端验证资源目录"), "insertion": .string("@手机阅读与跨端验证资源目录/")]),
                .object(["id": .string("file"), "kind": .string("file"), "label": .string("文档/完整功能对齐与验收步骤.md"), "path": .string("文档/完整功能对齐与验收步骤.md"), "insertion": .string("@文档/完整功能对齐与验收步骤.md")])
            ] : [.object(["id": .string("session"), "kind": .string("session"), "label": .string("检查 DeepSeek Harness 信息展示与手机操作"), "detail": .string("/Users/me/Projects/DSH-ANYWHERE"), "sourceSessionId": .string("a/b"), "insertion": .string("@[参考会话](dsh-session:ImEvYiI)"), "sameWorkspace": .bool(true)])]
            emit(type: "reference.candidates", id: command.requestId, payload: .object(["sessionId": .string("s"), "kind": .string(kind), "query": .string(query), "items": .array(items)]))
        } else if command.type == "feedback.list" {
            emit(type: "feedback.state", id: command.requestId, payload: .object(["sessionId": .string("s"), "nativeSequence": .number(100), "items": .array([
                .object(["messageId": .string("a"), "rating": .string("positive"), "version": .string("v2"), "note": .string("电脑端新增的评价备注"), "createdAt": .number(1), "updatedAt": .number(2)])])]))
        } else if command.type == "workspace.bytes" {
            let data = fileData ?? Data("文件已完整下载。\n\n可通过右上角的分享按钮保存到“文件”或在其他 App 中打开。\n".utf8)
            emit(type: command.type, id: command.requestId, payload: .object(["sessionId": .string("s"), "absolutePath": .string("/workspace/交付说明.txt"), "version": .string("v1"),
                "bytes": .number(Double(data.count)), "offset": .number(0), "data": .string(data.base64EncodedString()), "eof": .bool(true)]))
        }
    }
    func disconnect() async { continuation?.finish(); continuation = nil }
    func forgetPairing() async throws { await disconnect() }
    func setActiveMachine(_ machineId: String) async { }
    func removeMachine(_ machineId: String) async throws { }
    func pairedDevices() async throws -> [DSHRelayDevice] { [] }
    func revokeDevice(_ deviceId: String) async throws { }
    private func emit(type: String, id: String, payload: DSHJSONValue, sessionID: String? = nil) {
        sequence += 1
        continuation?.yield(DSHEvent(envelope: DSHEnvelope(messageId: id, deviceId: "device", machineId: "machine", sessionId: sessionID, sequence: sequence, type: type, payload: payload)))
    }
}

private struct DSHModelPanelFixtureView: View {
    @ObservedObject var fixture: DSHModelPanelFixture
    var body: some View {
        VStack {
            Spacer()
            Text("模型与智能").font(.title3)
            Spacer()
            Button("模型") { fixture.presented = true }
                .padding(16)
                .popover(isPresented: $fixture.presented, arrowEdge: .bottom) {
                    DSHModelConfigurationPanel(catalog: fixture.catalog, selection: $fixture.selection,
                        fallbackName: "muse", showsModels: $fixture.showsModels)
                        .presentationCompactAdaptation(.popover)
                        .presentationBackground(.regularMaterial)
                }
        }
        .padding(.bottom, 280)
    }
}

@MainActor
final class DSHModelPanelLayoutTests: XCTestCase {
    func testComputerConfigurationAndConflictFormsInLightDarkAndLargeText() async throws {
        let defaults = UserDefaults.standard
        let oldProfiles = defaults.object(forKey: DSHProfileStore.profilesKey), oldActive = defaults.object(forKey: DSHProfileStore.activeMachineKey)
        let profile = DSHRemoteProfile(relayBaseURL: URL(string: "https://example.test")!, deviceId: "device", machineId: "machine", machineName: "Fixture Mac")
        defaults.set(try JSONEncoder().encode([profile]), forKey: DSHProfileStore.profilesKey); defaults.set("machine", forKey: DSHProfileStore.activeMachineKey)
        defer { for (key, value) in [(DSHProfileStore.profilesKey, oldProfiles), (DSHProfileStore.activeMachineKey, oldActive)] { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let model = DSHAppModel(transport: DSHFileLayoutTransport(), isPaired: true, transactionDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        model.connect(); defer { model.disconnect() }
        for _ in 0..<40 { if model.connectionState == .connected { break }; try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(model.connectionState, .connected)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene), window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let namespace = try JSONDecoder().decode(DSHSettingsNamespace.self, from: JSONEncoder().encode(dshConfigurationLayoutNamespace()))
        let storage = DSHSecureConfigurationStorage(tokens: DSHKeychainTokenStore(service: "configuration-layout-\(UUID().uuidString)"))
        let key = storage.key(machine: "machine", device: "device", scope: "settings:llm-layout:\(DSHJSONValue.array([]).executionPrettyJSON)")
        let credentialKey = storage.key(machine: "machine", device: "device", scope: "credential:TEST_KEY")
        defer { try? storage.delete(key: key); try? storage.delete(key: credentialKey) }
        func capture(_ name: String) { let shot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }); shot.name = name; shot.lifetime = .keepAlways; add(shot) }
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            let home = UIHostingController(rootView: NavigationStack { DSHComputerConfigurationView() }.environmentObject(model).dynamicTypeSize(dark ? .accessibility2 : .large).frame(width: 320))
            window.rootViewController = home; window.makeKeyAndVisible(); try await Task.sleep(for: .milliseconds(650))
            capture(dark ? "configuration-home-dark-large-text" : "configuration-home-light")
            let raw = try JSONEncoder().encode(namespace), json = try JSONDecoder().decode(DSHJSONValue.self, from: raw)
            var old = json.executionObject; old["revision"] = .number(3)
            let previous = try JSONDecoder().decode(DSHSettingsNamespace.self, from: JSONEncoder().encode(DSHJSONValue.object(old)))
            var draft = DSHConfigurationDraft(base: previous); draft.edit(path: ["maxTokens"], value: .number(16384))
            try storage.save(draft, key: key)
            let editor = UIHostingController(rootView: NavigationStack { DSHSettingsEditor(namespace: namespace, writable: true, title: "模型配置", storage: storage) }.environmentObject(model).dynamicTypeSize(dark ? .accessibility2 : .large).frame(width: 320))
            window.rootViewController = editor; window.makeKeyAndVisible(); try await Task.sleep(for: .milliseconds(500))
            capture(dark ? "configuration-conflict-dark-large-text" : "configuration-conflict-light")
            func scrollViews(_ view: UIView) -> [UIScrollView] { (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
            if let scroll = scrollViews(editor.view).first(where: { $0.contentSize.height > $0.bounds.height }) {
                scroll.setContentOffset(.init(x: 0, y: max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
                try await Task.sleep(for: .milliseconds(250)); capture(dark ? "configuration-fields-dark-large-text-bottom" : "configuration-fields-light-bottom")
            }
            try storage.save(DSHJSONValue.object(["ref": .string("TEST_KEY"), "value": .string("fake-layout-secret")]), key: credentialKey)
            let credential = UIHostingController(rootView: NavigationStack { DSHCredentialEditor(initialRef: "TEST_KEY", storage: storage) }.environmentObject(model).dynamicTypeSize(dark ? .accessibility2 : .large).frame(width: 320))
            window.rootViewController = credential; window.makeKeyAndVisible(); try await Task.sleep(for: .milliseconds(500))
            capture(dark ? "credential-form-dark-large-text" : "credential-form-light")
            let discovered = try JSONDecoder().decode(DSHDiscoveredModels.self, from: Data(#"{"settingsNs":"llm-layout","models":[{"id":"reasoner","name":"已配置的推理模型","contextWindow":131072},{"id":"new-model-with-a-long-provider-identifier","name":"适合长文本与工具调用的新模型","contextWindow":262144,"maxTokens":32768}]}"#.utf8))
            let discovery = UIHostingController(rootView: NavigationStack { DSHModelDiscoveryView(settingsNs: "llm-layout", request: ["baseURL": .string("https://api.example.test/v1"), "api": .string("openai")], existing: [.object(["id": .string("reasoner")])], initialModels: discovered) { _, _ in } }.environmentObject(model).dynamicTypeSize(dark ? .accessibility2 : .large).frame(width: 320))
            window.rootViewController = discovery; window.makeKeyAndVisible(); try await Task.sleep(for: .milliseconds(450))
            capture(dark ? "model-discovery-dark-large-text" : "model-discovery-light")
            if let scroll = scrollViews(discovery.view).first(where: { $0.contentSize.height > $0.bounds.height }) {
                for _ in 0..<4 {
                    scroll.setContentOffset(.init(x: 0, y: max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
                    try await Task.sleep(for: .milliseconds(150))
                }
                capture(dark ? "model-discovery-dark-large-text-bottom" : "model-discovery-light-bottom")
            }

        }
    }
    func testNativeHistorySearchAndScheduleInLightDarkAndLargeText() async throws {
        let defaults = UserDefaults.standard
        let oldProfiles = defaults.object(forKey: DSHProfileStore.profilesKey), oldActive = defaults.object(forKey: DSHProfileStore.activeMachineKey)
        let profile = DSHRemoteProfile(relayBaseURL: URL(string: "https://example.test")!, deviceId: "device", machineId: "machine", machineName: "Fixture Mac")
        defaults.set(try JSONEncoder().encode([profile]), forKey: DSHProfileStore.profilesKey); defaults.set("machine", forKey: DSHProfileStore.activeMachineKey)
        defer {
            for (key, value) in [(DSHProfileStore.profilesKey, oldProfiles), (DSHProfileStore.activeMachineKey, oldActive)] {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let model = DSHAppModel(transport: DSHFileLayoutTransport(), isPaired: true, transactionDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        model.connect(); defer { model.disconnect() }
        for _ in 0..<40 { if model.connectionState == .connected { break }; try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(model.connectionState, .connected)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            let host = UIHostingController(rootView: NavigationStack {
                ScrollView { DSHHistorySearchResults(query: "手机").frame(width: 320).padding(.vertical, 12) }.navigationTitle("搜索对话").navigationBarTitleDisplayMode(.inline)
            }.environmentObject(model).dynamicTypeSize(dark ? .accessibility2 : .large))
            window.rootViewController = host; window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(750))
            let shot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
            shot.name = dark ? "history-search-dark-large-text" : "history-search-light"; shot.lifetime = .keepAlways; add(shot)
            let scheduleHost = UIHostingController(rootView: DSHSchedulePanel(sessionID: "s").environmentObject(model).dynamicTypeSize(dark ? .accessibility2 : .large).frame(width: 320))
            window.rootViewController = scheduleHost; window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(500))
            let schedule = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
            schedule.name = dark ? "schedule-dark-large-text" : "schedule-light"; schedule.lifetime = .keepAlways; add(schedule)
            if dark {
                func scrollViews(_ view: UIView) -> [UIScrollView] { (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
                if let scroll = scrollViews(scheduleHost.view).first(where: { $0.contentSize.height > $0.bounds.height }) {
                    scroll.setContentOffset(.init(x: 0, y: max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
                    try await Task.sleep(for: .milliseconds(250))
                    let bottom = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
                    bottom.name = "schedule-dark-large-text-bottom"; bottom.lifetime = .keepAlways; add(bottom)
                }
            }
        }
    }
    func testChildImageComposerAndQueuedAttachmentsInLightDarkAndLargeText() async throws {
        let profileDefaults = UserDefaults.standard
        let previousProfiles = profileDefaults.object(forKey: DSHProfileStore.profilesKey), previousActive = profileDefaults.object(forKey: DSHProfileStore.activeMachineKey)
        let profile = DSHRemoteProfile(relayBaseURL: URL(string: "https://example.test")!, deviceId: "device", machineId: "machine", machineName: "Fixture Mac")
        profileDefaults.set(try JSONEncoder().encode([profile]), forKey: DSHProfileStore.profilesKey); profileDefaults.set("machine", forKey: DSHProfileStore.activeMachineKey)
        defer {
            for (key, previous) in [(DSHProfileStore.profilesKey, previousProfiles), (DSHProfileStore.activeMachineKey, previousActive)] {
                if let previous { profileDefaults.set(previous, forKey: key) } else { profileDefaults.removeObject(forKey: key) }
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "child-media-layout-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let jpeg = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 200, height: 140)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 140))
            ("子任务参考图" as NSString).draw(at: CGPoint(x: 20, y: 55), withAttributes: [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.white])
        }.jpegData(compressionQuality: 0.85))
        let catalog = try JSONDecoder().decode(DSHSubagentCatalog.self, from: Data(#"{"parentSessionId":"parent","parentAvailable":true,"entries":[{"kind":"child","id":"child","mode":"continuable","activity":"running","hasChildren":false,"label":"分析图片中的界面"}]}"#.utf8))
        var state = DSHStoreState()
        state.subagentCatalogs = ["parent": catalog]
        state.messagesBySession["child"] = [DSHChatMessage(id: "a", role: .assistant, markdown: "可以继续发送图片。图片会由 Harness 校验并保存，发送失败时会保留草稿。")]
        let attachment = DSHMessageAttachment(id: "img", name: "参考图.jpg", mediaType: "image/jpeg", thumbnail: "data:image/jpeg;base64," + jpeg.base64EncodedString(), hostPath: "/host/参考图.jpg")
        let file = DSHMessageAttachment(id: "file", name: "完整功能实现与跨端验收说明.pdf", hostPath: "/host/说明.pdf")
        let item = DSHServerQueue.Item(id: "queue", placement: "queued", message: .init(id: "queue", content: [
            .object(["type": .string("text"), "text": .string("请按图片和说明继续处理。")]), .object(["type": .string("image")])]), attachments: [attachment, file])
        state.serverQueues = ["s": .init(sessionId: "s", available: true, items: [item])]
        let transport = DSHFileLayoutTransport()
        let model = DSHAppModel(transport: transport, initialState: state, isPaired: true, transactionDirectory: directory.appendingPathComponent("transactions"))
        model.connect()
        for _ in 0..<40 {
            if model.connectionState == .connected { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.connectionState, .connected)
        try await transport.seedMediaQueue(try XCTUnwrap(state.serverQueues?["s"]))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(model.serverQueue(for: "s")?.available == true)
        let drafts = DSHSubagentComposerDrafts(storage: DSHSubagentMediaStorage(directory: directory.appendingPathComponent("images")), defaults: defaults)
        let address = DSHSubagentDraftAddress(machineID: model.machineID, parentID: "parent", childID: "child")
        try await drafts.load(address); drafts.setText("请看这张参考图，继续检查顶部的显示效果。", for: address)
        try await drafts.setImages([.init(name: "photo.jpg", data: jpeg, isImage: true)], for: address)
        let child = try XCTUnwrap(catalog.entries.first), scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; model.disconnect() }
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            for queue in [false, true] {
                let view: AnyView = queue ? AnyView(QueuedPromptsSheet(sessionID: "s").environmentObject(model)) :
                    AnyView(NavigationStack { DSHSubagentRecord(parentID: "parent", child: child, composerDrafts: drafts) }.environmentObject(model))
                window.rootViewController = UIHostingController(rootView: view.dynamicTypeSize(dark ? .accessibility2 : .large).frame(width: 320))
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(400))
                let screenshot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
                screenshot.name = "\(queue ? "queue-attachments" : "child-image-composer")-\(dark ? "dark-large-text" : "light")"; screenshot.lifetime = .keepAlways; add(screenshot)
            }
        }
        model.disconnect()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotEqual(model.connectionState, .connected)
        let offline = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
        offline.name = "queue-attachments-dark-large-text-offline"; offline.lifetime = .keepAlways; add(offline)
    }
    func testFeedbackDraftAndCrossDeviceConflictInLightDarkAndLargeText() async throws {
        let defaults = UserDefaults.standard
        let previousProfiles = defaults.object(forKey: DSHProfileStore.profilesKey), previousActive = defaults.object(forKey: DSHProfileStore.activeMachineKey)
        let profile = DSHRemoteProfile(relayBaseURL: URL(string: "https://example.test")!, deviceId: "device", machineId: "machine", machineName: "Test Mac")
        defaults.set(try JSONEncoder().encode([profile]), forKey: DSHProfileStore.profilesKey); defaults.set("machine", forKey: DSHProfileStore.activeMachineKey)
        let draftKey = "dsh.feedback.draft." + Data(["machine", "s", "a"].joined(separator: "\u{0}").utf8).base64EncodedString()
        let previousDraft = defaults.object(forKey: draftKey)
        defer {
            for (key, previous) in [(DSHProfileStore.profilesKey, previousProfiles), (DSHProfileStore.activeMachineKey, previousActive), (draftKey, previousDraft)] {
                if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let draft = Data(#"{"base":{"messageId":"a","rating":"negative","version":"v1","createdAt":1,"updatedAt":1},"rating":"negative","category":"instruction-following","note":"手机端已经写好的备注：希望回答保留原生数据，并适合小屏阅读。其他端更新后，这段文字应继续保留。"}"#.utf8)
        let model = DSHAppModel(transport: DSHFileLayoutTransport(), isPaired: true,
            transactionDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        model.connect()
        for _ in 0..<40 {
            if model.connectionState == .connected { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(model.connectionState, .connected)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; model.disconnect() }
        for dark in [false, true] {
            defaults.set(draft, forKey: draftKey)
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            host.rootView = AnyView(DSHFeedbackEditor(sessionID: "s", messageID: "a", initialRating: "negative")
                .environmentObject(model).dynamicTypeSize(dark ? .accessibility2 : .large).frame(width: 320).id(UUID()))
            // The editor requests feedback from its appearance task; CI may need more
            // than one animation interval to mount the view and deliver the reply.
            let feedbackDeadline = Date().addingTimeInterval(5)
            while model.feedback(for: "a", in: "s")?.version != "v2", Date() < feedbackDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(model.feedback(for: "a", in: "s")?.version, "v2")
            try await Task.sleep(for: .milliseconds(150))
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
            attachment.name = "feedback-conflict-\(dark ? "dark-large-text" : "light")"; attachment.lifetime = .keepAlways; add(attachment)
            if dark {
                func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
                let layoutDeadline = Date().addingTimeInterval(5)
                var scrollView: UIScrollView?
                repeat {
                    host.view.layoutIfNeeded()
                    scrollView = descendants(host.view).compactMap { $0 as? UIScrollView }
                        .first { $0.bounds.height > 0 && $0.contentSize.height > $0.bounds.height }
                    if scrollView != nil { break }
                    try await Task.sleep(for: .milliseconds(25))
                } while Date() < layoutDeadline
                let scroll = try XCTUnwrap(scrollView)
                scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
                try await Task.sleep(for: .milliseconds(150))
                let bottom = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
                bottom.name = "feedback-conflict-dark-large-text-scrolled"; bottom.lifetime = .keepAlways; add(bottom)
            }
        }
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            for kind in ["file", "session"] {
                let pickerHost = UIHostingController(rootView: DSHReferencePicker(sessionID: "s", initialKind: kind, onInsert: { _ in })
                    .environmentObject(model).dynamicTypeSize(dark ? .accessibility2 : .large).frame(width: 320))
                window.rootViewController = pickerHost
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(500))
                let screenshot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
                screenshot.name = "references-\(kind)-\(dark ? "dark-large-text" : "light")"; screenshot.lifetime = .keepAlways; add(screenshot)
            }
        }
    }
    func testStructuredToolResultsInCompactWidthLightDarkAndLargeText() async throws {
        let model = DSHAppModel(transport: DSHPreviewTransport(), isPaired: false,
            transactionDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; model.disconnect() }
        let fixtures: [(String, DSHToolResult)] = [
            ("diff-search", .diff([DSHToolDiff(path: "Sources/对话界面/ConversationView.swift", oldText: "let title = name\nlet opaque = true\nrender(title)", newText: "let title = name\nlet opaque = false\nrender(title)")])),
            ("search", .search(DSHToolSearch(shape: "matches", files: [.init(path: "Sources/原生桥接/normalize.ts", matches: [.init(lineNumber: 137, line: "保留原生结果和真实子调用身份，手机端按文件分组展示。")])], paths: nil, truncated: true, total: 146))),
            ("web-terminal", .webSearch(DSHToolWebSearch(sources: [.init(url: "https://example.com/harness/reference", title: "Harness 工具展示参考", snippet: "原生元数据保留来源、摘要与日期；手机阅读时可以打开完整来源。", publishedAt: "2026-10-29")], answer: "**查询摘要**：保留来源与截断信息。", truncated: true)))
        ]
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            for (name, result) in fixtures {
                host.rootView = AnyView(NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            DSHToolResultContent(result: result, detail: nil, sessionID: "s", initiallyExpanded: true)
                            if name == "web-terminal" {
                                DSHToolResultContent(result: .terminal(output: "检查结果：发现 2 项需要处理。\n保持完整输出，可选择并复制。", exitCode: 2, signal: nil), detail: nil, sessionID: "s")
                            }
                        }.frame(width: 288).padding(16)
                    }.navigationTitle("工具结果").navigationBarTitleDisplayMode(.inline)
                }.environmentObject(model).dynamicTypeSize(dark ? .accessibility2 : .large))
                try await Task.sleep(for: .milliseconds(250))
                let screenshot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
                screenshot.name = "tools-\(name)-\(dark ? "dark-large-text" : "light")"; screenshot.lifetime = .keepAlways; add(screenshot)
                let fitting = host.sizeThatFits(in: CGSize(width: window.bounds.width, height: window.bounds.height))
                XCTAssertLessThanOrEqual(fitting.width, window.bounds.width + 1)
            }
        }
    }
    func testExecutionNoticesAndAttemptDetailsInCompactWidthAndLargeText() async throws {
        let records = try JSONDecoder().decode([DSHExecutionRecord].self, from: Data(#"[{"nativeSequence":0,"type":"turn/start","time":1000,"data":{"turn":1}},{"nativeSequence":1,"type":"step/start","time":1100,"data":{"turn":1,"step":1}},{"nativeSequence":2,"type":"assistant/attempt","time":1900,"data":{"turn":1,"step":1,"stream":[{"type":"reasoning-chunks","index":0,"time0":1200,"texts":["未展开不能出现的思考内容"],"dt":[]},{"type":"text-chunks","index":1,"time0":1300,"texts":["尚未提交的回答片段"],"dt":[]},{"type":"chunk","time":1800,"chunk":{"type":"finish","reason":{"kind":"error","failure":{"message":"服务商限流","code":"RATE_LIMIT","status":429}}}}]}},{"nativeSequence":3,"type":"llm/retry","time":2000,"data":{"turn":1,"step":1,"retryId":"r","retry":1,"maxRetries":3,"delayMs":4000,"provider":"DeepSeek","failure":{"message":"服务商限流，将按原计划重试。","code":"RATE_LIMIT","status":429}}},{"nativeSequence":4,"type":"step/end","time":2500,"data":{"turn":1,"step":1}},{"nativeSequence":5,"type":"turn/end","time":2600,"data":{"turn":1,"reason":{"kind":"aborted","reason":"user"}}},{"nativeSequence":6,"type":"compaction/start","time":3000,"data":{"compactionId":"c","turn":null}},{"nativeSequence":7,"type":"compaction/summary","time":4000,"data":{"compactionId":"c","summary":[{"type":"text","text":"保留目标、已完成的验证和接下来需要处理的工作。"}],"shadowedSeqs":[12,4],"shadowedTokenCount":1200,"provider":"DeepSeek","model":"reasoner"}},{"nativeSequence":8,"type":"compaction/checkpoint","time":4100,"data":{"compactionId":"c"}},{"nativeSequence":9,"type":"compaction/end","time":4200,"data":{"compactionId":"c","turn":null}}]"#.utf8))
        var state = DSHStoreState(); state.executionBySession = ["s": records]
        let model = DSHAppModel(transport: DSHPreviewTransport(), initialState: state, isPaired: false,
            transactionDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; model.disconnect() }
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            host.rootView = AnyView(NavigationStack {
                ScrollView { VStack(spacing: 12) {
                    ForEach(DSHExecutionNotice.build(records)) { notice in DSHExecutionNoticeCard(sessionID: "s", notice: notice, initiallyExpanded: true) }
                }.frame(width: 320).padding(.vertical) }
                    .navigationTitle("执行过程").navigationBarTitleDisplayMode(.inline)
            }.environmentObject(model).dynamicTypeSize(dark ? .accessibility2 : .large))
            try await Task.sleep(for: .milliseconds(400))
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
            attachment.name = dark ? "execution-notices-dark-large-text" : "execution-notices-light"
            attachment.lifetime = .keepAlways; add(attachment)
            if dark {
                func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
                let scroll = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIScrollView }.first { $0.contentSize.height > $0.bounds.height })
                scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
                try await Task.sleep(for: .milliseconds(150))
                let bottom = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
                bottom.name = "execution-notices-dark-large-text-scrolled"; bottom.lifetime = .keepAlways; add(bottom)
            }
        }
        let lifecycle = try JSONDecoder().decode(DSHExecutionLifecycle.self, from: Data(#"{"createdAt":1793280000000,"inheritedEventCount":360,"throughSeq":382,"ownEventCount":23,"turnsStarted":3,"turnsEnded":2,"measuredTurns":2,"endedTurnMilliseconds":81750,"timingIncomplete":true,"assistantMessages":4,"toolCalls":8,"lastActivityAt":1793280300000,"lastEndKind":"aborted","openTurn":{"turn":4,"startedAt":1793280300000}}"#.utf8))
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            host.rootView = AnyView(NavigationStack { List { DSHExecutionLifecycleSection(lifecycle: lifecycle) }.navigationTitle("子任务执行轨迹").navigationBarTitleDisplayMode(.inline) }.dynamicTypeSize(dark ? .accessibility2 : .large).frame(width: 320))
            try await Task.sleep(for: .milliseconds(400))
            func capture(_ suffix: String) {
                let shot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
                shot.name = "execution-lifecycle-\(dark ? "dark-large-text" : "light")\(suffix)"; shot.lifetime = .keepAlways; add(shot)
            }
            capture("")
            if dark {
                func scrollViews(_ view: UIView) -> [UIScrollView] { (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
                if let scroll = scrollViews(host.view).first(where: { $0.contentSize.height > $0.bounds.height }) {
                    for _ in 0..<3 { scroll.setContentOffset(.init(x: 0, y: max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false); try await Task.sleep(for: .milliseconds(150)) }
                    capture("-bottom")
                }
            }
        }
        let attempt = try XCTUnwrap(records.first { $0.type == "assistant/attempt" })
        host.rootView = AnyView(NavigationStack { DSHExecutionDetail(sessionID: "s", record: attempt) }.environmentObject(model))
        try await Task.sleep(for: .milliseconds(400))
        let detail = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
        detail.name = "execution-attempt-detail-thinking-collapsed"; detail.lifetime = .keepAlways; add(detail)
    }

    func testWorkspaceBrowserAndFilePreviewInLightDarkAndLargeText() async throws {
        let defaults = UserDefaults.standard
        let previousProfiles = defaults.object(forKey: DSHProfileStore.profilesKey)
        let previousActive = defaults.object(forKey: DSHProfileStore.activeMachineKey)
        let profile = DSHRemoteProfile(relayBaseURL: URL(string: "https://example.test")!, deviceId: "device", machineId: "machine", machineName: "Test Mac")
        defaults.set(try JSONEncoder().encode([profile]), forKey: DSHProfileStore.profilesKey)
        defaults.set("machine", forKey: DSHProfileStore.activeMachineKey)
        defer {
            if let previousProfiles { defaults.set(previousProfiles, forKey: DSHProfileStore.profilesKey) }
            else { defaults.removeObject(forKey: DSHProfileStore.profilesKey) }
            if let previousActive { defaults.set(previousActive, forKey: DSHProfileStore.activeMachineKey) }
            else { defaults.removeObject(forKey: DSHProfileStore.activeMachineKey) }
        }
        let transport = DSHFileLayoutTransport()
        let model = DSHAppModel(transport: transport, isPaired: true,
            transactionDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        model.connect()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; model.disconnect() }
        try await Task.sleep(for: .milliseconds(200))
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            host.rootView = AnyView(DSHRemoteFilesPanel(sessionID: "s").environmentObject(model)
                .dynamicTypeSize(dark ? .accessibility2 : .large))
            try await Task.sleep(for: .milliseconds(1100))
            window.layoutIfNeeded()
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
            attachment.name = dark ? "workspace-files-dark-large-text" : "workspace-files-light"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        host.rootView = AnyView(DSHRemoteFilePreview(reference: .init(sessionID: "s", path: "交付说明.txt")).environmentObject(model))
        try await Task.sleep(for: .milliseconds(900))
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
        attachment.name = "workspace-file-text-preview"; attachment.lifetime = .keepAlways; add(attachment)
        let illustration = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            ("完整附件预览" as NSString).draw(at: CGPoint(x: 32, y: 98), withAttributes: [.font: UIFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: UIColor.white])
        }
        await transport.setFileData(try XCTUnwrap(illustration.pngData()))
        host.rootView = AnyView(DSHRemoteFilePreview(reference: .init(sessionID: "s", path: "/host/objects/hash", name: "界面图片.png"))
            .id("image-preview").environmentObject(model))
        try await Task.sleep(for: .milliseconds(900))
        let imageAttachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
        imageAttachment.name = "workspace-file-image-preview"; imageAttachment.lifetime = .keepAlways; add(imageAttachment)
    }

    func testWorkflowReadabilityInCompactWidthAndLargeText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let run = try JSONDecoder().decode(DSHWorkflowRun.self, from: Data(#"{"id":"r","name":"并行检查与交付","status":"interrupted","startedAt":1000,"finishedAt":12000,"members":[{"seq":1,"phase":"检查","label":"审阅历史回放与实时状态的合并","childId":"a","status":"completed"},{"seq":2,"phase":"检查","label":"核对父子会话身份与模式","childId":"b","status":"failed"},{"seq":3,"phase":"","label":"补充兼容验证","childId":"c","status":"cancelled"},{"seq":4,"label":"汇总交付结果","childId":"d","status":"interrupted"}]}"#.utf8))
        let model = DSHAppModel(transport: DSHPreviewTransport(), isPaired: false,
            transactionDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; model.disconnect() }
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            host.rootView = AnyView(NavigationStack {
                ScrollView {
                    DSHWorkflowRunCard(sessionID: "s", run: run, initiallyExpanded: true,
                        initiallyExpandedPhases: Set(run.phases.map(\.id)))
                        .frame(width: 320).padding(.vertical)
                }
                .navigationTitle("工作流记录").navigationBarTitleDisplayMode(.inline)
            }.environmentObject(model).dynamicTypeSize(dark ? .accessibility2 : .large))
            try await Task.sleep(for: .milliseconds(400))
            window.layoutIfNeeded()
            XCTAssertGreaterThan(host.view.bounds.width, 320)
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            })
            attachment.name = dark ? "workflow-compact-dark-large-text" : "workflow-compact-light"
            attachment.lifetime = .keepAlways
            add(attachment)
            if dark {
                func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
                let scroll = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIScrollView }
                    .first(where: { $0.contentSize.height > $0.bounds.height + 1 }))
                scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
                try await Task.sleep(for: .milliseconds(200))
                let bottom = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                })
                bottom.name = "workflow-compact-dark-large-text-scrolled"
                bottom.lifetime = .keepAlways
                add(bottom)
            }
        }
    }
    func testGoalEditorShowsConflictInLightDarkAndLargeText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let goalState = try JSONDecoder().decode(DSHGoalState.self, from: Data(#"{"sessionId":"s","goal":{"id":"g","revision":2,"objective":"让 iOS 尽量还原桌面 Harness 信息，并适合手机阅读和操作。","phase":"active","maxGoalRounds":12},"roundsStarted":3}"#.utf8))
        let newer = try JSONDecoder().decode(DSHGoalState.self, from: Data(#"{"sessionId":"s","goal":{"id":"g","revision":3,"objective":"电脑上新增：保留原生任务状态和审批交互，并验证掉线后恢复。","phase":"active","maxGoalRounds":18},"roundsStarted":4}"#.utf8))
        var state = DSHStoreState()
        state.goalBySession = ["s": newer]
        let model = DSHAppModel(transport: DSHPreviewTransport(), initialState: state, isPaired: false,
            transactionDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let goal = try XCTUnwrap(goalState.goal)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; model.disconnect() }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            host.rootView = AnyView(DSHGoalEditor(sessionID: "s", goal: goal).environmentObject(model)
                .dynamicTypeSize(dark ? .accessibility2 : .large))
            try await Task.sleep(for: .milliseconds(400))
            window.layoutIfNeeded()
            let textViews = descendants(host.view).compactMap { $0 as? UITextView }
            let fields = descendants(host.view).compactMap { $0 as? UITextField }
            XCTAssertEqual(textViews.count, 1)
            XCTAssertEqual(fields.count, 1)
            for view in textViews.map({ $0 as UIView }) + fields.map({ $0 as UIView }) {
                let rect = view.convert(view.bounds, to: host.view)
                XCTAssertGreaterThan(rect.width, 150)
                XCTAssertGreaterThanOrEqual(rect.minX, 0)
                XCTAssertLessThanOrEqual(rect.maxX, host.view.bounds.width + 1)
            }
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            })
            attachment.name = dark ? "goal-conflict-dark-accessibility" : "goal-conflict-light"
            attachment.lifetime = .keepAlways
            add(attachment)
            if dark {
                let scroll = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIScrollView }
                    .first(where: { $0 is UICollectionView || $0 is UITableView }))
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
                try await Task.sleep(for: .milliseconds(200))
                let scrolled = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                })
                scrolled.name = "goal-conflict-dark-accessibility-scrolled"
                scrolled.lifetime = .keepAlways
                add(scrolled)
            }
        }
    }
    func testNewAndExistingConversationsShareEditorGeometry() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        let model = DSHAppModel.preview()
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap(descendants)
        }
        for collapsed in [true, false] {
            model.collapseComposerControls = collapsed
            var widths: [CGFloat] = []
            for isNew in [true, false] {
                if isNew {
                    host.rootView = AnyView(NewSessionSheet().environmentObject(model))
                } else {
                    host.rootView = AnyView(NavigationStack {
                        ConversationView(sessionID: "preview-session").environmentObject(model)
                    })
                }
                try await Task.sleep(for: .milliseconds(500))
                let editors = descendants(host.view).filter { $0 is UITextField || $0 is UITextView }
                XCTAssertEqual(editors.count, 1)
                let editor = try XCTUnwrap(editors.first)
                XCTAssertTrue(editor.becomeFirstResponder())
                try await Task.sleep(for: .milliseconds(250))
                window.layoutIfNeeded()
                widths.append(editor.bounds.width)
                let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                })
                attachment.name = "shared-editor-\(isNew ? "new" : "conversation")-\(collapsed ? "compact" : "all-actions")"
                attachment.lifetime = .keepAlways
                add(attachment)
                editor.resignFirstResponder()
            }
            XCTAssertEqual(widths[0], widths[1], accuracy: 1)
        }
    }

    func testPopoverBoundsStayStableAcrossListAndModelChanges() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let fixture = DSHModelPanelFixture()
        let host = UIHostingController(rootView: DSHModelPanelFixtureView(fixture: fixture))
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        fixture.presented = true
        try await Task.sleep(for: .milliseconds(600))
        let presented = try XCTUnwrap(host.presentedViewController)
        let original = presented.view.bounds.size
        XCTAssertGreaterThanOrEqual(original.width, 330)
        XCTAssertGreaterThanOrEqual(original.height, 190)

        func capture(_ name: String) {
            window.layoutIfNeeded()
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            })
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture("model-panel-light-xhigh")
        fixture.showsModels = true
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(presented.view.bounds.size, original)
        capture("model-panel-list")
        fixture.showsModels = false
        for selection in [
            DSHModelSelection(provider: "test", model: "muse", reasoningEffort: "minimal"),
            DSHModelSelection(provider: "test", model: "short", reasoningEffort: "high"),
            DSHModelSelection(provider: "test", model: "plain"),
            DSHModelSelection(provider: "test", model: "muse", reasoningEffort: "xhigh")
        ] {
            withAnimation(.spring()) { fixture.selection = selection }
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertEqual(presented.view.bounds.size, original)
            capture("model-panel-\(selection.model)-\(selection.reasoningEffort ?? "none")")
        }
        window.overrideUserInterfaceStyle = .dark
        try await Task.sleep(for: .milliseconds(200))
        capture("model-panel-dark")
        fixture.presented = false
        try await Task.sleep(for: .milliseconds(200))
    }
}
#endif

final class DSHProtocolTests: XCTestCase {
    func testConfigurationEditsKeepUnknownFieldsAndWriteArraysAsOneNativeValue() throws {
        let namespace = try JSONDecoder().decode(DSHSettingsNamespace.self, from: Data(#"{"ns":"llm-test","revision":4,"schema":{"type":"object"},"value":{"models":[{"id":"m","future":{"keep":true},"maxTokens":100}],"other":"untouched"},"applies":"live","secrets":[]}"#.utf8))
        var draft = DSHConfigurationDraft(base: namespace)
        draft.edit(path: ["models", "0", "maxTokens"], value: .number(200), arrayRoot: ["models"])
        XCTAssertEqual(draft.edits.count, 1)
        XCTAssertEqual(draft.edits[0].path, ["models"])
        XCTAssertEqual(draft.edits[0].value?.configurationValue(at: ["0", "future", "keep"]), .bool(true))
        XCTAssertEqual(draft.value.configurationValue(at: ["other"]), .string("untouched"))
        draft.edit(path: ["providers", "new"], value: .object([:]))
        draft.edit(path: ["providers", "new", "baseURL"], value: .string("https://test.invalid"))
        XCTAssertEqual(draft.edits.filter { $0.path == ["providers", "new"] }.count, 1)
        XCTAssertEqual(draft.edits.last?.value?.configurationValue(at: ["baseURL"]), .string("https://test.invalid"))
        let fieldKey = DSHJSONValue.array(["models", "0", "maxTokens"].map(DSHJSONValue.string)).executionPrettyJSON
        draft.rawNumbers[fieldKey] = "stale input"
        draft.invalidNumbers.insert(fieldKey)
        draft.edit(path: ["models", "0"], value: nil, arrayRoot: ["models"])
        XCTAssertTrue(draft.rawNumbers.isEmpty)
        XCTAssertTrue(draft.invalidNumbers.isEmpty)
    }
    func testExecutionLifecycleDecodesIndependentOfPageAndDoesNotPretendAnOpenTurnFinished() throws {
        let page = try JSONDecoder().decode(DSHExecutionPage.self, from: Data(#"{"sessionId":"child","records":[],"hasMore":false,"lifecycle":{"createdAt":1000,"inheritedEventCount":20,"throughSeq":24,"ownEventCount":5,"turnsStarted":2,"turnsEnded":1,"measuredTurns":1,"endedTurnMilliseconds":2000,"timingIncomplete":false,"assistantMessages":1,"toolCalls":1,"lastEndKind":"aborted","openTurn":{"turn":3,"startedAt":8000}}}"#.utf8))
        XCTAssertEqual(page.lifecycle?.inheritedEventCount, 20)
        XCTAssertEqual(page.lifecycle?.endedTurnMilliseconds, 2000)
        XCTAssertEqual(page.lifecycle?.endDescription, "已取消")
        XCTAssertEqual(page.lifecycle?.openTurn?.turn, 3)
        XCTAssertNil(try JSONDecoder().decode(DSHExecutionPage.self, from: Data(#"{"sessionId":"old-host","records":[],"hasMore":false}"#.utf8)).lifecycle)
    }
    func testDiscoveredModelImportAppendsUniqueIDsAndPreservesConfiguredUnknownFields() throws {
        let found = try JSONDecoder().decode(DSHDiscoveredModels.self, from: Data(#"{"settingsNs":"llm-test","models":[{"id":"old","name":"Changed by server"},{"id":"new","name":"New","contextWindow":131072,"maxTokens":8192},{"id":"new","name":"Duplicate"}]}"#.utf8))
        let original: DSHJSONValue = .object(["id": .string("old"), "name": .string("My name"), "future": .bool(true)])
        let imported = found.appending(to: [original], selected: ["old", "new"])
        XCTAssertEqual(imported.count, 2); XCTAssertEqual(imported.first, original)
        XCTAssertEqual(imported.last?.executionObject["contextWindow"], .number(131072))
        XCTAssertEqual(imported.last?.executionObject["maxTokens"], .number(8192))
        XCTAssertEqual(found.appending(to: [original], selected: []), [original])
    }
    func testConfigurationSchemaResolvesNativeReferenceEnvelopeAndEnumWithoutGuessingUIDs() throws {
        let json = try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"uid":1,"refs":{"1":{"type":"object","dict":{"thinking":2}},"2":{"type":"union","list":[3,4]},"3":{"type":"const","value":"enabled"},"4":{"type":"const","value":"disabled"}}}"#.utf8))
        let schema = DSHConfigurationSchema(document: json)
        XCTAssertEqual(schema.at(["thinking"])["type"], .string("union"))
        XCTAssertEqual(schema.choices(schema.at(["thinking"])), [.string("enabled"), .string("disabled")])
        XCTAssertTrue(schema.node(.number(1e100)).isEmpty)
        let models = try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"type":"object","dict":{"providers":{"type":"array","inner":{"type":"object","dict":{"models":{"type":"array","inner":{"type":"string"}}}}}}}"#.utf8))
        XCTAssertEqual(DSHConfigurationSchema(document: models).arrayRoot(in: ["providers", "0", "models", "0"]), ["providers"])
    }
    @MainActor
    func testSecureConfigurationDraftRejectsLateReceiptOverwritingAnotherEditorsNewInput() throws {
        let tokens = DSHKeychainTokenStore(service: "configuration-tests-\(UUID().uuidString)"), storage = DSHSecureConfigurationStorage(tokens: tokens)
        let key = storage.key(machine: "mac", device: "phone", scope: "credential:TEST_KEY")
        defer { try? storage.delete(key: key) }
        let first = try storage.save(["value": "first-test-secret", "pending": "original-request"], key: key, expecting: nil)
        let editorB = try storage.loadRecord([String: String].self, key: key)
        let newer = try storage.save(["value": "newer-test-secret"], key: key, expecting: editorB.token)
        XCTAssertThrowsError(try storage.save(["value": ""], key: key, expecting: first))
        XCTAssertEqual(try tokens.read(account: key), newer)
        XCTAssertEqual(try storage.load([String: String].self, key: key)?["value"], "newer-test-secret")
        XCTAssertNotEqual(key, storage.key(machine: "other-mac", device: "phone", scope: "credential:TEST_KEY"))
        XCTAssertNil(try tokens.read(account: storage.key(machine: "mac", device: "other-phone", scope: "credential:TEST_KEY")))
    }
    func testScheduleRulesKeepOriginalTimezoneInstantAndNativeFrequency() throws {
        let items = try JSONDecoder().decode([DSHScheduleRecord].self, from: Data(#"[{"id":"r","kind":"every","prompt":"Inspect","everySeconds":300,"scheduledAt":"2026-10-30T00:00:00.000Z"},{"id":"once","kind":"after","prompt":"Review","afterSeconds":3600,"scheduledAt":"2026-10-30T00:00:00Z"}]"#.utf8))
        XCTAssertEqual(items[0].date, items[1].date)
        XCTAssertEqual(items[0].frequencyLabel, "每 5 分钟")
        XCTAssertEqual(items[1].frequencyLabel, "延时 1 小时 · 一次")
        XCTAssertNotNil(items[0].date)
    }
    func testHistoryCoverageMergesOverlapAndExposesUnloadedIntervals() {
        var coverage = DSHHistoryCoverage()
        coverage.include(.init(sessionId: "s", throughSeq: 100, fromSeq: 90, toSeq: 100, hasMore: true))
        coverage.include(.init(sessionId: "s", throughSeq: 100, fromSeq: 10, toSeq: 20, hasMore: true))
        XCTAssertEqual(coverage.gaps, [.init(lower: 21, upper: 89)])
        XCTAssertEqual(coverage.nextBefore, 90)
        coverage.include(.init(sessionId: "s", throughSeq: 100, fromSeq: 20, toSeq: 89, hasMore: true))
        XCTAssertEqual(coverage.ranges, [.init(lower: 10, upper: 100)])
        coverage.include(.init(sessionId: "s", throughSeq: 100, fromSeq: 0, toSeq: 9, hasMore: false))
        XCTAssertTrue(coverage.gaps.isEmpty)
        XCTAssertNil(coverage.nextBefore)
        coverage.include(.init(sessionId: "s", throughSeq: 200, fromSeq: 300, toSeq: 200, hasMore: true))
        XCTAssertEqual(coverage.throughSeq, 100, "Invalid coverage cannot mark an unknown interval loaded")
    }

    func testHistoryGapBreaksReasoningAndTaskTimelineGrouping() {
        let messages: [DSHChatMessage] = [.init(id: "old", role: .assistant, markdown: "", reasoning: "Old reasoning", nativeSequence: 10),
            .init(id: "new", role: .assistant, markdown: "New answer", nativeSequence: 100)]
        let sections = messages.transcriptEntries(with: [], historyGaps: [.init(lower: 11, upper: 99)]).groupedTurns().withTaskTimelines()
        XCTAssertEqual(sections.count, 3)
        guard case .row(.historyGap) = sections[1], case .turn(let old, _) = sections[0], case .turn(let new, _) = sections[2] else { return XCTFail("A missing interval must remain a distinct row") }
        XCTAssertEqual(old.messages.map(\.id), ["old"])
        XCTAssertEqual(new.messages.map(\.id), ["new"])
        XCTAssertEqual(new.taskTimeline?.messages.map(\.id), ["new"])
    }

    func testMessageDecodeRetainsNativeIdentityAndInterruptedStateAcrossPersistence() throws {
        let message = try JSONDecoder().decode(DSHChatMessage.self, from: Data(#"{"id":"a","role":"assistant","markdown":"Partial","nativeSequence":0,"replacesMessageId":"delta","interrupted":true}"#.utf8))
        XCTAssertEqual(message.nativeSequence, 0)
        XCTAssertEqual(message.replacesMessageId, "delta")
        XCTAssertEqual(message.interrupted, true)
        XCTAssertEqual(try JSONDecoder().decode(DSHChatMessage.self, from: JSONEncoder().encode(message)), message)
    }
    func testNativeSessionReferenceURIUsesExactOpaqueIdentityAndReferenceInsertionKeepsDraft() throws {
        XCTAssertEqual(DSHSessionReference.sessionID(from: try XCTUnwrap(URL(string: "dsh-session:ImEvYiI"))), "a/b")
        XCTAssertNil(DSHSessionReference.sessionID(from: try XCTUnwrap(URL(string: "dsh-session:e30"))))
        XCTAssertNil(DSHSessionReference.sessionID(from: try XCTUnwrap(URL(string: "dsh-session:ImEvYiI="))))
        XCTAssertNil(DSHSessionReference.sessionID(from: try XCTUnwrap(URL(string: "https://example.com/ImEvYiI"))))
        XCTAssertEqual(dshAppendReference("@\"目录/a b.md\"", to: "阅读"), "阅读 @\"目录/a b.md\" ")
        XCTAssertEqual(dshAppendReference("@[Title](dsh-session:ImEvYiI)", to: "已有草稿\n"), "已有草稿\n@[Title](dsh-session:ImEvYiI) ")
    }
    func testToolResultDecodingPreservesNativeSearchReadAndWebFactsAndFallsBackOnInvalidMetadata() throws {
        func result(_ name: String, _ json: String, status: String = "succeeded") throws -> DSHToolResult? {
            var tool = DSHToolActivity(id: "t", name: name, status: status)
            tool.resultMeta = try JSONDecoder().decode(DSHJSONValue.self, from: Data(json.utf8))
            return DSHToolResult.parse(tool)
        }
        guard case .search(let search) = try result("grep", #"{"shape":"matches","files":[{"path":"文档.md","matches":[{"lineNumber":31,"line":"检查输出"}]}],"total":12,"truncated":true}"#) else { return XCTFail("Missing search projection") }
        XCTAssertEqual(search.files?.first?.matches.first?.lineNumber, 31)
        XCTAssertEqual(search.total, 12); XCTAssertTrue(search.truncated)
        XCTAssertNil(try result("grep", #"{"shape":"matches","files":[{"path":"a","matches":[{"lineNumber":0,"line":"bad"}]}],"total":1,"truncated":false}"#))
        guard case .search(let empty) = try result("glob", #"{"shape":"paths","paths":[],"total":0,"truncated":false}"#) else { return XCTFail("Zero matches are valid") }
        XCTAssertEqual(empty.paths, [])
        guard case .read(let read) = try result("read", #"{"path":"a.ts","offset":9,"lines":[{"number":9,"text":"a"},{"number":12,"text":"b"}],"totalLines":12}"#) else { return XCTFail("Missing numbered read") }
        XCTAssertEqual(read.lines.map(\.number), [9, 12])
        XCTAssertNil(try result("read", #"{"path":"a","offset":9,"lines":[{"number":8,"text":"bad"}],"totalLines":12}"#))
        XCTAssertNil(try result("read", #"{"path":"a","offset":1,"lines":[{"number":2,"text":"a"},{"number":2,"text":"b"}],"totalLines":12}"#))
        guard case .webSearch(let web) = try result("web_search", #"{"sources":[{"url":"https://example.com/a","title":"标题","snippet":"摘要","publishedAt":"2026-10-29"}],"answer":"结论","truncated":true}"#) else { return XCTFail("Missing sources") }
        XCTAssertEqual(web.sources.first?.publishedAt, "2026-10-29"); XCTAssertTrue(web.truncated)
        XCTAssertNil(try result("web_search", #"{"sources":[],"truncated":false}"#, status: "failed"))
        XCTAssertNil(try result("other_plugin", #"{"diffs":[{"path":"a","oldText":null,"newText":"b"}]}"#))
        XCTAssertNil(DSHToolResult.webURL("javascript:alert(1)")); XCTAssertNil(DSHToolResult.webURL("file:///private/a"))
        XCTAssertNotNil(DSHToolResult.webURL("https://example.com/a"))
    }

    func testTerminalExitMarkersMatchNativeContractWithoutInventingStatusOnInfrastructureFailures() {
        func result(_ text: String, status: String = "succeeded") -> DSHToolResult? {
            DSHToolResult.parse(DSHToolActivity(id: "t", name: "bash", status: status, detail: text))
        }
        XCTAssertEqual(result("output\n[exit code: 2]"), .terminal(output: "output", exitCode: 2, signal: nil))
        XCTAssertEqual(result("output\n[killed by signal: SIGTERM]"), .terminal(output: "output", exitCode: nil, signal: "SIGTERM"))
        XCTAssertEqual(result("output"), .terminal(output: "output", exitCode: 0, signal: nil))
        XCTAssertEqual(result("[exit code: 2]"), .terminal(output: "[exit code: 2]", exitCode: 0, signal: nil))
        XCTAssertNil(result("spawn failed", status: "failed"))
    }

    func testDiffKeepsContextAndDistinguishesNullBeforeImageAndLargeWrites() {
        let lines = DSHToolDiffLine.lines(DSHToolDiff(path: "a", oldText: "context\nbefore\ntail", newText: "context\nafter\ntail"))
        XCTAssertEqual(lines.map(\.kind), [" ", "−", "+", " "])
        XCTAssertEqual(lines.map(\.text), ["context", "before", "after", "tail"])
        XCTAssertEqual(DSHToolDiffLine.lines(DSHToolDiff(path: "a", oldText: nil, newText: "new")).map(\.kind), ["+"])
        XCTAssertEqual(DSHToolDiffLine.lines(DSHToolDiff(path: "a", oldText: "", newText: "new")).map(\.kind), ["+"])
        let large = DSHToolDiffLine.lines(DSHToolDiff(path: "a", oldText: nil, newText: Array(repeating: "line", count: 2_001).joined(separator: "\n")))
        XCTAssertEqual(large.count, 2_001); XCTAssertTrue(large.allSatisfy { $0.kind == "+" })
    }

    func testSubcallsUseNativeParentIdentityAndOrphansAndCyclesRemainReadable() {
        let root = DSHToolActivity(id: "root", name: "run_code")
        var child = DSHToolActivity(id: "child", name: "read", status: "failed")
        child.rootCallId = root.id; child.parentCallId = root.id
        var nested = DSHToolActivity(id: "nested", name: "glob")
        nested.rootCallId = root.id; nested.parentCallId = child.id
        let tree = DSHToolActivity.nested([root, child, nested])
        XCTAssertEqual(tree.map(\.id), ["root"])
        XCTAssertEqual(tree.first?.children?.first?.status, "failed")
        XCTAssertEqual(tree.first?.children?.first?.children?.first?.id, "nested")
        XCTAssertEqual(DSHToolActivity.nested([child, nested]).count, 2)
        child.parentCallId = nested.id; child.rootCallId = nested.id
        XCTAssertEqual(DSHToolActivity.nested([child, nested]).count, 2)
    }
    func testRetryCountdownRequiresConfirmedCurrentOwnerAndAnUnclosedNativeWait() throws {
        let retry = DSHExecutionRecord(nativeSequence: 3, type: "llm/retry", time: 1_000,
            data: ["retryId": .string("r"), "turn": .number(1), "step": .number(1), "delayMs": .number(5000)])
        let notice = try XCTUnwrap(DSHExecutionNotice.build([retry]).first)
        XCTAssertTrue(notice.canCountDown(connected: true, sessionRunning: true, latestTurn: 1))
        XCTAssertFalse(notice.canCountDown(connected: false, sessionRunning: true, latestTurn: 1))
        XCTAssertFalse(notice.canCountDown(connected: true, sessionRunning: false, latestTurn: 1))
        XCTAssertFalse(notice.canCountDown(connected: true, sessionRunning: true, latestTurn: 2))
        XCTAssertFalse(notice.canCountDown(connected: true, sessionRunning: true, latestTurn: nil))
        let end = DSHExecutionRecord(nativeSequence: 4, type: "turn/end", time: 2000,
            data: ["turn": .number(1), "reason": .object(["kind": .string("aborted")])])
        let closed = try XCTUnwrap(DSHExecutionNotice.build([retry, end]).first)
        XCTAssertFalse(closed.canCountDown(connected: true, sessionRunning: true, latestTurn: 1))
    }
    func testNativeExecutionNoticesStayBetweenCachedMessagesAfterRelayReplayRenumbersEvents() throws {
        let messages = [DSHChatMessage(id: "u", role: .user, markdown: "Task", sequence: 100, nativeSequence: 0),
            DSHChatMessage(id: "a", role: .assistant, markdown: "Before", sequence: 101, nativeSequence: 3),
            DSHChatMessage(id: "b", role: .assistant, markdown: "After", sequence: 102, nativeSequence: 7)]
        let retry = DSHExecutionRecord(nativeSequence: 5, type: "llm/retry", time: nil, data: ["retryId": .string("r"), "turn": .number(1), "step": .number(1)], sequence: 1000)
        let notices = DSHExecutionNotice.build([retry])
        XCTAssertEqual(messages.transcriptEntries(with: [], execution: notices).map(\.id), ["turn-u", "turn-a", "execution-retry:r", "turn-b"])
        let legacyTool = DSHToolActivity(id: "legacy", name: "read", sequence: 101)
        let first = messages.transcriptEntries(with: [legacyTool], execution: notices).map(\.id)
        XCTAssertEqual(first, messages.transcriptEntries(with: [legacyTool], execution: notices).map(\.id))
    }
    func testExecutionStreamAssemblyKeepsSettledBlocksAndFirstTokenLatency() throws {
        let record = try JSONDecoder().decode(DSHExecutionRecord.self, from: Data(#"{"nativeSequence":9,"type":"assistant/attempt","time":2000,"data":{"turn":1,"step":2,"stream":[{"type":"reasoning-chunks","index":0,"time0":1100,"dt":[40],"texts":["","Thought"]},{"type":"text-chunks","index":1,"time0":1200,"dt":[20],"texts":["Hel","lo"]},{"type":"chunk","time":1300,"chunk":{"type":"block-end","index":1,"block":{"type":"text","text":"Hello"}}},{"type":"chunk","time":1400,"chunk":{"type":"finish","reason":{"kind":"error","failure":{"message":"Limited","code":"RATE_LIMIT"}}}}]}}"#.utf8))
        XCTAssertEqual(record.firstTokenTime, 1140)
        XCTAssertEqual(record.output.text, "Hello", "A block-end replaces deltas rather than duplicating them")
        XCTAssertEqual(record.output.reasoning, "Thought")
        XCTAssertEqual(record.finish?.executionObject["kind"], .string("error"))
    }
    func testRetryChainUsesExplicitStartsAndOnlyCancelsPendingWaitAtOwningBoundary() throws {
        func record(_ seq: Int64, _ type: String, _ data: [String: DSHJSONValue]) -> DSHExecutionRecord {
            DSHExecutionRecord(nativeSequence: seq, type: type, time: seq * 1000, data: data)
        }
        let one = record(1, "llm/retry", ["retryId": .string("r"), "turn": .number(1), "step": .number(2), "retry": .number(1)])
        let started = record(2, "llm/retry-started", ["retryId": .string("r"), "turn": .number(1), "step": .number(2), "retry": .number(1)])
        let two = record(3, "llm/retry", ["retryId": .string("r"), "turn": .number(1), "step": .number(2), "retry": .number(2)])
        let wrong = record(4, "step/end", ["turn": .number(1), "step": .number(3)])
        let close = record(5, "step/end", ["turn": .number(1), "step": .number(2)])
        XCTAssertEqual(DSHExecutionNotice.build([one, started, wrong]).first?.retryState, "started")
        XCTAssertEqual(DSHExecutionNotice.build([one, started, two, wrong]).first?.retryState, "scheduled")
        let notice = try XCTUnwrap(DSHExecutionNotice.build([one, started, two, wrong, close]).first)
        XCTAssertEqual(notice.retryState, "cancelled")
        XCTAssertEqual(notice.records.map(\.nativeSequence), [1, 2, 3])
    }
    func testExecutionGroupsKeepHeaderInsideItsNativeTurnAndStandaloneCompactionSeparate() {
        let records = [DSHExecutionRecord(nativeSequence: 0, type: "turn/start", time: nil, data: ["turn": .number(1)]),
            DSHExecutionRecord(nativeSequence: 1, type: "request/header", time: nil, data: [:]),
            DSHExecutionRecord(nativeSequence: 2, type: "turn/end", time: nil, data: ["turn": .number(1), "reason": .object(["kind": .string("completed")])]),
            DSHExecutionRecord(nativeSequence: 3, type: "compaction/start", time: nil, data: ["turn": .null, "compactionId": .string("c")]),
            DSHExecutionRecord(nativeSequence: 4, type: "compaction/summary", time: nil, data: ["compactionId": .string("c")])]
        let groups = DSHExecutionGroup.build(records)
        XCTAssertEqual(groups.map(\.id), ["turn:1", "compaction:c"])
        XCTAssertEqual(groups[0].records.map(\.nativeSequence), [0, 1, 2])
        XCTAssertEqual(groups[0].title, "轮次 1 · 完成")
        let invalid = DSHExecutionRecord(nativeSequence: 10, type: "step/start", time: nil, data: ["turn": .number(1e100)])
        XCTAssertNil(invalid.turn, "Malformed extension data must not trap in Int conversion")
    }
    func testNativeFileAddressesKeepSessionAndAbsolutePathGrammar() throws {
        func reference(_ address: String) throws -> DSHFileReference { try XCTUnwrap(DSHFileReference(url: try XCTUnwrap(URL(string: address)), sessionID: "current")) }
        XCTAssertEqual(try reference("dsh-resource://file/session/other%2Fa/%2Ftmp/%E5%9B%BE.png?x=1#preview"), .init(sessionID: "other/a", path: "/tmp/图.png"))
        XCTAssertEqual(try reference("dsh-resource://file/absolute/tmp/a.pdf").path, "/tmp/a.pdf")
        XCTAssertEqual(try reference("dsh-resource://file/absolute/C%3A/Users/a.txt").path, "C:/Users/a.txt")
        XCTAssertEqual(try reference("dsh-resource://file/absolute//server/share/a.txt").path, "//server/share/a.txt")
        XCTAssertEqual(try reference("file:///tmp/a%20b.txt").path, "/tmp/a b.txt")
        XCTAssertNil(DSHFileReference(url: URL(string: "https://example.com/a.pdf")!, sessionID: "s"))
        XCTAssertNil(DSHFileReference(url: URL(string: "file://other-host/a.pdf")!, sessionID: "s"))
        let links = DSHFileReference.links(in: "[文件](dsh-resource://file/session/s/output.pdf) [重复](dsh-resource://file/session/s/output.pdf) [网页](https://example.com)\n\n```\n[代码示例](/not-a-real-link)\n```", sessionID: "current")
        XCTAssertEqual(links, [.init(sessionID: "s", path: "output.pdf")])
        let image = DSHMessageAttachment(id: "image", name: "Image", mediaType: "image/png", hostPath: "/host/objects/hash")
        XCTAssertEqual(image.fileReference(sessionID: "s"), .init(sessionID: "s", path: "/host/objects/hash", name: "Image.png"))
        let legacy = try JSONDecoder().decode(DSHMessageAttachment.self, from: Data(#"{"id":"old","name":"Old file"}"#.utf8))
        XCTAssertNil(legacy.hostPath)
        XCTAssertNil(legacy.fileReference(sessionID: "s"))
    }
    func testWorkflowPhasesKeepAbsentEmptyAndUnicodeIdentitiesDistinct() throws {
        let run = try JSONDecoder().decode(DSHWorkflowRun.self, from: Data(#"{"id":"r","name":"Review","status":"running","members":[{"seq":1,"label":"A","childId":"a","status":"completed"},{"seq":2,"label":"B","phase":"","childId":"b","status":"running"},{"seq":3,"label":"C","phase":"missing","childId":"c","status":"failed"},{"seq":4,"label":"D","phase":"😀","childId":"d","status":"cancelled"}]}"#.utf8))
        XCTAssertEqual(run.phases.count, 4)
        XCTAssertEqual(run.phases.map(\.id), ["missing", "value:0:", "value:7:missing", "value:2:😀"])
        XCTAssertEqual(run.phases[1].members.first?.childId, "b")
        XCTAssertNil(run.sequence)
    }
    func testSubagentHistoryAddressPreservesParentAndLifecycleMode() throws {
        let command = DSHCommand.openSession(deviceId: "phone", machineId: "mac", sessionId: "child",
                                             parentSessionId: "parent", subagentMode: "one-shot")
        XCTAssertEqual(command.payload, .object(["sessionId": .string("child"),
            "parentSessionId": .string("parent"), "subagentMode": .string("one-shot")]))
        let catalog = try JSONDecoder().decode(DSHSubagentCatalog.self, from: Data(#"{"parentSessionId":"parent","parentAvailable":false,"entries":[{"kind":"child","id":"child","mode":"one-shot","activity":"inactive","hasChildren":true},{"kind":"diagnostic","id":"bad","reason":"corrupt"}]}"#.utf8))
        XCTAssertEqual(catalog.entries[0].mode, "one-shot")
        XCTAssertEqual(catalog.entries[1].reason, "corrupt")
    }
    func testQueueItemsKeepAttachmentsAndQueueCommandsUseOccurrenceIdentity() throws {
        let queue = try JSONDecoder().decode(DSHServerQueue.self, from: Data(#"{"sessionId":"s","available":true,"items":[{"id":"item","placement":"queued","rpcId":"rpc","message":{"id":"item","content":[{"type":"text","text":"Task"},{"type":"file","receiptId":"receipt"}]}}]}"#.utf8))
        XCTAssertEqual(queue.items[0].text, "Task")
        XCTAssertFalse(queue.items[0].isTextOnly)
        XCTAssertEqual(queue.items[0].rpcId, "rpc")
        let command = DSHCommand.updateQueue(deviceId: "phone", machineId: "mac", sessionId: "s", itemId: "item", action: "remove")
        XCTAssertEqual(command.type, "queue.update")
        XCTAssertEqual(command.payload, .object(["itemId": .string("item"), "action": .string("remove")]))
    }
    func testNativeForkUsesHostSequenceAndNeverCopiesPromptText() throws {
        let command = DSHCommand.forkSession(deviceId: "phone", machineId: "mac", sessionId: "parent", atSeq: 42, requestId: "fork-1")
        XCTAssertEqual(command.type, "session.fork")
        XCTAssertEqual(command.payload, .object(["atSeq": .number(42)]))
        let message = try JSONDecoder().decode(DSHChatMessage.self, from: Data(#"{"id":"a","role":"assistant","markdown":"Done","nativeSequence":42}"#.utf8))
        XCTAssertEqual(message.nativeSequence, 42)
        XCTAssertNil(message.sequence, "Relay ordering must remain independent of Host fork boundaries")
        let legacy = try JSONDecoder().decode(DSHChatMessage.self, from: Data(#"{"id":"old","role":"assistant","markdown":"Done"}"#.utf8))
        XCTAssertNil(legacy.nativeSequence)
    }
    func testMacCatalogWireFixturesKeepEmptyWorkspacesAndCustomModes() throws {
        func event(_ type: String, _ payload: String) throws -> DSHEvent {
            let json = """
            {"version":1,"messageId":"request-1","machineId":"mac","deviceId":"iphone",
             "sequence":42,"timestamp":1,"type":"\(type)","payload":\(payload)}
            """
            return try JSONDecoder().decode(DSHEvent.self, from: Data(json.utf8))
        }
        let workspaces = try event("workspace.catalog", #"{"workspaces":[{"id":"empty-project","title":"没有会话的项目","path":"/Users/mac/项目"}]}"#)
        guard case .workspaceCatalog(let entries) = workspaces.kind else { return XCTFail("Mac workspace catalog was not decoded") }
        XCTAssertEqual(entries.first?.name, "没有会话的项目")
        XCTAssertEqual(entries.first?.path, "/Users/mac/项目")
        let modes = try event("mode.catalog", #"{"defaultMode":"custom-review","modes":[{"id":"custom-review","name":"我的审查模式","description":"来自 Mac 的自定义模式"}]}"#)
        guard case .modeCatalog(let catalog) = modes.kind else { return XCTFail("Mac mode catalog was not decoded") }
        XCTAssertEqual(catalog.defaultMode, "custom-review")
        XCTAssertEqual(catalog.modes.first?.name, "我的审查模式")
        let directory = try event("directory.list", #"{"path":"/","directories":[{"name":"Users","path":"/Users"}]}"#)
        guard case .directoryListing(let listing) = directory.kind else { return XCTFail("Mac directory listing was not decoded") }
        XCTAssertNil(listing.parentPath)
        XCTAssertEqual(listing.directories.first?.path, "/Users")
        XCTAssertEqual(directory.envelope.messageId, "request-1")
    }

    func testRemoteWorkspaceAndRenameCommandsOmitAbsentOptionalFields() throws {
        let workspace = DSHCommand.createWorkspace(deviceId: "iphone", machineId: "mac", path: "/Users/mac/项目")
        let data = try JSONEncoder().encode(workspace)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["sessionId"])
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["path"] as? String, "/Users/mac/项目")
        XCTAssertNil(payload["title"])
        let rename = DSHCommand.renameSession(deviceId: "iphone", machineId: "mac", sessionId: "conversation", title: "新的名称", requestId: "rename-1")
        XCTAssertEqual(rename.requestId, "rename-1")
        XCTAssertEqual(rename.sessionId, "conversation")
        XCTAssertEqual(rename.payload, .object(["title": .string("新的名称")]))
    }

    func testEnvelopeRoundTripsUnknownPayload() throws {
        let envelope = DSHEnvelope(messageId: "m1", deviceId: "d1", machineId: "mac",
                                   sessionId: "s1", sequence: 4, timestamp: 123,
                                   type: "future.event",
                                   payload: .object(["answer": .number(42), "nested": .array([.bool(true)])]))
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(DSHEvent.self, from: data)
        XCTAssertEqual(decoded.envelope, envelope)
        XCTAssertEqual(decoded.kind, .unknown)
    }

    func testResumeCommandContainsLastSequenceAndBearerIsNotPayload() throws {
        let command = DSHCommand.resume(deviceId: "d", machineId: "m", lastSequence: 99)
        XCTAssertEqual(command.type, "connection.resume")
        XCTAssertEqual(command.payload, .object(["lastSequence": .number(99)]))
        let prompt = DSHCommand.sendPrompt(deviceId: "d", machineId: "m", sessionId: "s", text: "hello")
        XCTAssertEqual(prompt.payload, .object(["text": .string("hello")]))
    }

    func testStreamingOpenSessionExplicitlyOptsIn() {
        let command = DSHCommand.openSession(deviceId: "d", machineId: "m", sessionId: "s", streaming: true)
        XCTAssertEqual(command.payload, .object(["sessionId": .string("s"), "streaming": .bool(true)]))
    }

    func testLiveTurnStatusKeepsCompletedCurrentHarnessToolVisible() {
        let messages = [
            DSHChatMessage(id: "old-user", role: .user, markdown: "old", sequence: 10),
            DSHChatMessage(id: "new-user", role: .user, markdown: "new", sequence: 100),
            // Harness sends an empty assistant frame for a tool call. It must
            // not hide the useful completion that follows it.
            DSHChatMessage(id: "tool-frame", role: .assistant, markdown: "", sequence: 101),
        ]
        let tools = [
            DSHToolActivity(id: "old-tool", name: "bash", status: "completed",
                            detail: #"{"command":"old"}"#, sequence: 11),
            DSHToolActivity(id: "current-tool", name: "bash", status: "completed",
                            detail: #"{"command":"swift build"}"#, sequence: 102),
        ]

        XCTAssertEqual(DSHLiveTurnStatusProjection.trail(messages: messages, tools: tools),
                       "已完成 · Bash · swift build")
        XCTAssertFalse(DSHLiveTurnStatusProjection.hasRunningTool(messages: messages, tools: tools))
        XCTAssertFalse(DSHLiveTurnStatusProjection.shouldShow(turnState: "completed",
                                                               messages: messages, tools: tools))
    }

    func testLiveTurnStatusUsesCurrentStreamingReasoningAndRunningTool() {
        let messages = [
            DSHChatMessage(id: "user", role: .user, markdown: "inspect", sequence: 100),
            DSHChatMessage(id: "thinking", role: .assistant, markdown: "",
                           reasoning: "正在检查 Harness 轨迹", sequence: 104),
        ]
        let completed = DSHToolActivity(id: "done", name: "read", status: "completed",
                                        detail: #"{"path":"old.swift"}"#, sequence: 102)
        XCTAssertEqual(DSHLiveTurnStatusProjection.trail(messages: messages, tools: [completed]),
                       "思考中…")

        let running = DSHToolActivity(id: "running", name: "read", status: "running",
                                      detail: #"{"path":"live.swift"}"#, sequence: 103)
        XCTAssertEqual(DSHLiveTurnStatusProjection.trail(messages: messages, tools: [completed, running]),
                       "读取 · live.swift")
        XCTAssertTrue(DSHLiveTurnStatusProjection.hasRunningTool(messages: messages,
                                                                  tools: [completed, running]))
    }

    func testLiveTurnStatusDoesNotReusePreviousTurnActivity() {
        let messages = [
            DSHChatMessage(id: "old-user", role: .user, markdown: "old", sequence: 10),
            DSHChatMessage(id: "new-user", role: .user, markdown: "new", sequence: 100),
        ]
        let oldTool = DSHToolActivity(id: "old-tool", name: "read", status: "running",
                                      detail: #"{"path":"old.swift"}"#, sequence: 11)
        XCTAssertNil(DSHLiveTurnStatusProjection.trail(messages: messages, tools: [oldTool]))
        XCTAssertFalse(DSHLiveTurnStatusProjection.hasRunningTool(messages: messages, tools: [oldTool]))
    }

    func testHistoricalRunningToolDoesNotStartAClockWhenOpeningACompletedConversation() {
        let messages = [
            DSHChatMessage(id: "user", role: .user, markdown: "build", sequence: 100),
            DSHChatMessage(id: "answer", role: .assistant, markdown: "Done", sequence: 104),
        ]
        let staleTool = DSHToolActivity(id: "stale", name: "bash", status: "running", sequence: 102)
        for state in ["idle", "completed", "cancelled", "failed"] {
            XCTAssertFalse(DSHLiveTurnStatusProjection.shouldShow(turnState: state,
                messages: messages, tools: [staleTool]))
        }
        XCTAssertTrue(DSHLiveTurnStatusProjection.shouldShow(turnState: "running",
            messages: messages, tools: []))
    }

    func testOpenSessionCommandCarriesTheSessionID() {
        let command = DSHCommand.openSession(deviceId: "d", machineId: "m", sessionId: "s")
        XCTAssertEqual(command.type, "session.open")
        XCTAssertEqual(command.sessionId, "s")
        XCTAssertEqual(command.payload, .object(["sessionId": .string("s")]))
    }

    func testModelSelectionCarriesTheCatalogReasoningEffort() {
        let command = DSHCommand.selectModel(deviceId: "device", machineId: "machine",
                                             sessionId: "session", provider: "deepseek",
                                             model: "deepseek-v4.1-flash",
                                             reasoningEffort: "high")
        XCTAssertEqual(command.type, "session.model")
        XCTAssertEqual(command.payload, .object([
            "provider": .string("deepseek"),
            "model": .string("deepseek-v4.1-flash"),
            "reasoningEffort": .string("high"),
        ]))
    }

    func testAttachmentPromptKeepsTextInsideCanonicalContent() throws {
        let prompt = DSHCommand.sendPrompt(deviceId: "d", machineId: "m", sessionId: "s",
                                            text: "这是啥?",
                                            attachments: [.object(["type": .string("file"),
                                                                  "receiptId": .string("receipt-1")])])
        guard case .object(let payload) = prompt.payload,
              case .array(let content) = payload["content"] else {
            return XCTFail("attachment prompt must carry a content array")
        }
        XCTAssertEqual(content.first,
                       .object(["type": .string("text"), "text": .string("这是啥?")]))
        XCTAssertEqual(content.last,
                       .object(["type": .string("file"), "receiptId": .string("receipt-1")]))
    }

    func testProtocolErrorIsDecodedAndCorrelatedByMessageId() throws {
        let envelope = DSHEnvelope(messageId: "request-1", deviceId: "d", machineId: "m",
                                   sequence: 1, type: "protocol.error",
                                   payload: .object(["code": .string("bridge-request-failed"),
                                                     "message": .string("upload failed"),
                                                     "retryable": .bool(true)]))
        let event = DSHEvent(envelope: envelope)
        XCTAssertEqual(event.kind, .protocolError(DSHProtocolError(code: "bridge-request-failed",
                                                                     message: "upload failed",
                                                                     retryable: true)))
    }

    func testRelayURLPreservesTheRelayOrigin() throws {
        XCTAssertEqual(
            try DSHAPIClient.relayBaseURL(from: "https://relay.example.com").absoluteString,
            "https://relay.example.com"
        )
        XCTAssertEqual(
            try DSHAPIClient.relayBaseURL(from: "http://localhost:8787").absoluteString,
            "http://localhost:8787"
        )
        XCTAssertThrowsError(try DSHAPIClient.relayBaseURL(from: "http://relay.example.com"))
    }

    func testRelayPayloadRoundTripsACommand() throws {
        let command = DSHCommand.sendPrompt(deviceId: "device", machineId: "machine",
                                             sessionId: "session", text: "hello")
        let payload = try DSHRelayPayloadMessage.wrapping(machineId: "machine", sender: .device, body: command)
        let data = try JSONEncoder().encode(payload)
        let decoded = try DSHRelayMessage(from: data)
        guard case .payload(let received) = decoded else {
            return XCTFail("expected relay payload")
        }
        let decodedCommand = try received.decodeBody(DSHCommand.self)
        XCTAssertEqual(decodedCommand.type, "prompt.send")
        XCTAssertEqual(decodedCommand.sessionId, "session")
    }

    func testRelayPayloadOmitsNilOptionalFields() throws {
        let command = DSHCommand.resume(deviceId: "device", machineId: "machine", lastSequence: 0)
        let payload = try DSHRelayPayloadMessage.wrapping(machineId: "machine", sender: .device, body: command)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertNil(object["targetDeviceId"])
        let body = try XCTUnwrap(object["body"] as? [String: Any])
        XCTAssertNil(body["sessionId"])
        XCTAssertEqual(body["type"] as? String, "connection.resume")
    }

    func testPairingLinkParsesTheConnectorPayload() throws {
        let link = try XCTUnwrap(DSHPairingLink(
            urlString: "dshanywhere://pair?relay=https%3A%2F%2Frelay.example.com&machineId=machine_macmini&secret=s3cret-value-long-enough"
        ))
        XCTAssertEqual(link.relay, "https://relay.example.com")
        XCTAssertEqual(link.machineId, "machine_macmini")
        XCTAssertEqual(link.credential, .secret("s3cret-value-long-enough"))
    }

    func testPairingLinkRejectsForeignOrIncompleteCodes() {
        // A generic URL QR, a missing field, a blank secret and a non-URL must
        // all be refused, so the scanner stays armed for the real code.
        XCTAssertNil(DSHPairingLink(urlString: "https://example.com/?machineId=mac-1"))
        XCTAssertNil(DSHPairingLink(urlString: "dshanywhere://pair?machineId=mac-1"))
        XCTAssertNil(DSHPairingLink(urlString: "dshanywhere://pair?relay=https%3A%2F%2Fr.example&machineId=mac-1&secret="))
        XCTAssertNil(DSHPairingLink(urlString: "dshanywhere://pair?relay=https%3A%2F%2Fr.example&machineId=mac-1"))
        XCTAssertNil(DSHPairingLink(urlString: "not a url"))
    }

    func testPairingLinkCarriesASingleUseCode() throws {
        let link = try XCTUnwrap(DSHPairingLink(
            urlString: "dshanywhere://pair?relay=https%3A%2F%2Frelay.example.com&machineId=machine_macmini&code=abcd2345"
        ))
        // Codes are normalised to upper case so a hand-typed lower-case entry
        // still matches the Relay's hashed lookup.
        XCTAssertEqual(link.credential, .code("ABCD2345"))
    }

    func testPairingLinkPrefersTheCodeWhenBothArePresent() throws {
        let link = try XCTUnwrap(DSHPairingLink(
            urlString: "dshanywhere://pair?relay=https%3A%2F%2Fr.example&machineId=m&code=abcd2345&secret=long-lived-secret"
        ))
        XCTAssertEqual(link.credential, .code("ABCD2345"))
    }

    func testPairingCredentialDetectionSeparatesCodesFromSecrets() {
        // One field accepts both, so the split must be by shape alone.
        XCTAssertEqual(DSHPairingCredential.detect("abcd2345"), .code("ABCD2345"))
        XCTAssertEqual(DSHPairingCredential.detect("  abcd2345  "), .code("ABCD2345"))
        XCTAssertEqual(DSHPairingCredential.detect("s3cret-value-long-enough"), .secret("s3cret-value-long-enough"))
        // 8 characters, but not the code alphabet: 0/O/1/I/L are excluded.
        XCTAssertEqual(DSHPairingCredential.detect("ABCDEFG0"), .secret("ABCDEFG0"))
        XCTAssertNil(DSHPairingCredential.detect("   "))
        XCTAssertNil(DSHPairingCredential.detect(""))
    }

    func testPairingLinkRejectsARelayTheClientCannotDial() {
        XCTAssertNil(DSHPairingLink(
            urlString: "dshanywhere://pair?relay=ftp%3A%2F%2Frelay.example.com&machineId=mac-1&secret=abcdefghijklmnop"
        ))
    }

    /// Goes through `transcriptEntries`, the path the app actually renders, so
    /// these assertions cannot pass while the real grouping is broken.
    private func turnBlocks(_ messages: [DSHChatMessage]) -> [DSHTranscriptBlock] {
        messages.transcriptEntries(with: []).compactMap {
            if case .turn(let block) = $0 { return block }
            return nil
        }
    }

    func testConsecutiveAssistantMessagesBecomeOneTurnBlock() {
        let messages = [
            DSHChatMessage(id: "u1", role: .user, markdown: "do it"),
            DSHChatMessage(id: "a1", role: .assistant, markdown: "step one", reasoning: "think one"),
            DSHChatMessage(id: "a2", role: .assistant, markdown: "step two", reasoning: "think two"),
            DSHChatMessage(id: "u2", role: .user, markdown: "again"),
            DSHChatMessage(id: "a3", role: .assistant, markdown: "done"),
        ]

        let blocks = turnBlocks(messages)

        // One turn = one block, so the phone folds that turn's reasoning once
        // instead of once per assistant message.
        XCTAssertEqual(blocks.map(\.id), ["u1", "a1", "u2", "a3"])
        XCTAssertEqual(blocks[0].isUserTurn, true)
        XCTAssertEqual(blocks[0].messages.count, 1)
        XCTAssertEqual(blocks[1].messages.count, 2)
        XCTAssertEqual(blocks[1].reasoning, "think one\n\nthink two")
        XCTAssertEqual(blocks[3].reasoning, "")
    }

    func testTurnBlockHidesAnswersThatHaveNotStreamedYet() {
        // Reasoning can land before the streamed text, producing a message with
        // an empty body; it must contribute reasoning without an empty bubble.
        let block = turnBlocks([
            DSHChatMessage(id: "a1", role: .assistant, markdown: "", reasoning: "thinking"),
            DSHChatMessage(id: "a2", role: .assistant, markdown: "the answer"),
        ])[0]

        XCTAssertEqual(block.visibleMessages.map(\.id), ["a2"])
        XCTAssertEqual(block.reasoning, "thinking")
    }

    func testAttachmentOnlyUserMessageRemainsVisible() {
        let attachment = DSHMessageAttachment(id: "receipt-1", name: "photo.jpg",
                                               mediaType: "image/jpeg", receiptId: "receipt-1")
        let block = turnBlocks([
            DSHChatMessage(id: "u1", role: .user, markdown: "", attachments: [attachment])
        ])[0]

        // An image-only prompt has an empty text field, but it is still a real
        // user turn and must render its thumbnail in the transcript.
        XCTAssertEqual(block.visibleMessages.map(\.id), ["u1"])
    }

    // MARK: - Web-parity tool presentation

    func testToolVerbsMirrorTheWebClient() {
        // Mirrors dsh-client-ui-tool's variant/title tables verbatim.
        XCTAssertEqual(DSHToolPresentation.title(for: "read"), "读取")
        XCTAssertEqual(DSHToolPresentation.title(for: "read_image"), "读取图片")
        XCTAssertEqual(DSHToolPresentation.title(for: "web_search"), "搜索")
        XCTAssertEqual(DSHToolPresentation.title(for: "web_fetch"), "读取")
        XCTAssertEqual(DSHToolPresentation.title(for: "grep"), "搜索")
        XCTAssertEqual(DSHToolPresentation.title(for: "write"), "写入")
        XCTAssertEqual(DSHToolPresentation.title(for: "edit"), "编辑")
        XCTAssertEqual(DSHToolPresentation.title(for: "bash"), "Bash")
        XCTAssertEqual(DSHToolPresentation.title(for: "run_code"), "代码")
        XCTAssertEqual(DSHToolPresentation.title(for: "job_output"), "工具调用")
    }

    func testToolHeadlinePicksTheCallTarget() {
        let read = DSHToolActivity(id: "t", name: "read", status: "running",
                                   detail: #"{"file_path":"docs/IOS-PENDING.md"}"#,
                                   arguments: #"{"file_path":"docs/IOS-PENDING.md"}"#)
        XCTAssertEqual(DSHToolPresentation.headline(for: read), "读取 · docs/IOS-PENDING.md")
        let bash = DSHToolActivity(id: "t", name: "bash", status: "succeeded",
                                   detail: "done",
                                   arguments: #"{"command":"ls -la","description":"list files"}"#)
        XCTAssertEqual(DSHToolPresentation.headline(for: bash), "Bash · list files")
        let bare = DSHToolActivity(id: "t", name: "job_output", status: "running")
        XCTAssertEqual(DSHToolPresentation.headline(for: bare), "工具调用")
    }

    func testToolStatusWordsMirrorTheWebClient() {
        XCTAssertEqual(DSHToolPresentation.statusText("running"), "运行中")
        XCTAssertEqual(DSHToolPresentation.statusText("succeeded"), "已完成")
        XCTAssertEqual(DSHToolPresentation.statusText("failed"), "失败")
        XCTAssertEqual(DSHToolPresentation.statusText("cancelled"), "已取消")
    }

    func testThumbnailDataURLDecodes() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let attachment = DSHMessageAttachment(id: "sha256:abc", name: "shot.png",
                                              mediaType: "image/png",
                                              thumbnail: "data:image/png;base64,\(bytes.base64EncodedString())")
        XCTAssertEqual(attachment.thumbnailData, bytes)
        XCTAssertNil(dshDataURLBytes("https://example.com/shot.png"))
        XCTAssertNil(dshDataURLBytes("data:image/png,not-base64!!"))
        XCTAssertNil(DSHMessageAttachment(id: "x", name: "shot.png").thumbnailData)
    }

    func testNearestEffortIndexSurvivesIdDrift() {
        // The persisted effort id can drift from the catalog's ids; the meter
        // must point at the nearest intelligence, never slam to minimum.
        let efforts = [
            DSHModelReasoningEffort(id: "low", name: "低"),
            DSHModelReasoningEffort(id: "medium", name: "中"),
            DSHModelReasoningEffort(id: "high", name: "高"),
        ]
        XCTAssertEqual(dshNearestReasoningEffortIndex(efforts, to: "high"), 2)
        XCTAssertEqual(dshNearestReasoningEffortIndex(efforts, to: "xhigh"), 2)
        XCTAssertEqual(dshNearestReasoningEffortIndex(efforts, to: "minimal"), 0)
        XCTAssertEqual(dshNearestReasoningEffortIndex([], to: "high"), 0)
    }

    // MARK: - Relay device management

    private func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DSHStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testDeviceListSendsTheDeviceTokenAndDecodesTheRelayShape() async throws {
        DSHStubURLProtocol.handler = { _ in
            (200, Data(#"{"devices":[{"deviceId":"device_1","name":"iPhone","createdAt":1735000000000}]}"#.utf8))
        }
        defer { DSHStubURLProtocol.handler = nil }

        let client = DSHAPIClient(relayBaseURL: URL(string: "https://relay.example.com")!,
                                  session: stubbedSession())
        let devices = try await client.devices(machineId: "mac-1", token: "device-token")

        XCTAssertEqual(devices.map(\.deviceId), ["device_1"])
        XCTAssertEqual(devices.first?.name, "iPhone")
        // The path and bearer header are the parts a refactor can silently break.
        XCTAssertEqual(DSHStubURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(DSHStubURLProtocol.lastRequest?.url?.path, "/v1/machines/mac-1/devices")
        XCTAssertEqual(DSHStubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer device-token")
    }

    func testRevokeUsesDeleteOnTheDevicePath() async throws {
        DSHStubURLProtocol.handler = { _ in (200, Data(#"{"revoked":true,"deviceId":"device_2"}"#.utf8)) }
        defer { DSHStubURLProtocol.handler = nil }

        let client = DSHAPIClient(relayBaseURL: URL(string: "https://relay.example.com")!,
                                  session: stubbedSession())
        try await client.revokeDevice(machineId: "mac-1", deviceId: "device_2", token: "device-token")

        XCTAssertEqual(DSHStubURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(DSHStubURLProtocol.lastRequest?.url?.path, "/v1/machines/mac-1/devices/device_2")
    }

    func testDeviceListSurfacesTheRelayErrorInsteadOfEmptySuccess() async throws {
        // An older relay answers 404 here; that must surface as an error, not as
        // a machine that happens to have no devices.
        DSHStubURLProtocol.handler = { _ in (404, Data(#"{"error":"not_found"}"#.utf8)) }
        defer { DSHStubURLProtocol.handler = nil }

        let client = DSHAPIClient(relayBaseURL: URL(string: "https://relay.example.com")!,
                                  session: stubbedSession())
        do {
            _ = try await client.devices(machineId: "mac-1", token: "device-token")
            XCTFail("expected the relay error to surface")
        } catch let error as DSHAPIError {
            XCTAssertEqual(error, .http(status: 404, message: "not_found"))
        }
    }
    func testLanguageIdentifiersMatchTheLocalizationFolders() {
        // The raw values are the .lproj folder names the catalogue compiles to.
        // A mismatch would not fail to build; it would silently serve English,
        // which is exactly the kind of bug nobody notices until a user reports it.
        XCTAssertEqual(DSHLanguage.english.rawValue, "en")
        XCTAssertEqual(DSHLanguage.simplifiedChinese.rawValue, "zh-Hans")
        XCTAssertEqual(DSHLanguage.allCases.count, 3)
    }

    func testFollowSystemMeansNoLocaleOverride() {
        XCTAssertNil(DSHLanguage.system.locale, "system must fall through to the device")
        XCTAssertEqual(DSHLanguage.simplifiedChinese.locale?.identifier, "zh-Hans")
        XCTAssertEqual(DSHLanguage.english.locale?.identifier, "en")
    }


    // MARK: - Markdown blocks

    func testHeadingsCodeListsAndTablesAreRecognised() {
        // The whole point: `AttributedString(markdown:)` would hand every one of
        // these back as its literal markers.
        let source = """
        ## Summary

        Some prose.

        ```sh
        curl -s https://example.com/health
        ```

        - first
        - second

        | a | b |
        |---|---|
        | 1 | 2 |

        ---
        """

        let kinds = DSHMarkdown.blocks(from: source).map(\.kind)

        XCTAssertEqual(kinds.count, 6)
        guard case .heading(let level, let text) = kinds[0] else { return XCTFail("expected heading") }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(text, "Summary")
        guard case .paragraph(let prose) = kinds[1] else { return XCTFail("expected paragraph") }
        XCTAssertEqual(prose, "Some prose.")
        guard case .code(let language, let body) = kinds[2] else { return XCTFail("expected code") }
        XCTAssertEqual(language, "sh")
        XCTAssertEqual(body, "curl -s https://example.com/health")
        guard case .bullets(let items) = kinds[3] else { return XCTFail("expected bullets") }
        XCTAssertEqual(items, ["first", "second"])
        guard case .table(let header, let rows) = kinds[4] else { return XCTFail("expected table") }
        XCTAssertEqual(header, ["a", "b"])
        XCTAssertEqual(rows, [["1", "2"]])
        XCTAssertEqual(kinds[5], .divider)
    }

    func testCodeFenceWithoutClosingStillEndsTheBlock() {
        // Swallowing the remainder as code would hide everything after it.
        let kinds = DSHMarkdown.blocks(from: "```\nlet x = 1\nafter").map(\.kind)
        XCTAssertEqual(kinds.count, 1)
        guard case .code(_, let body) = kinds[0] else { return XCTFail("expected code") }
        XCTAssertEqual(body, "let x = 1\nafter")
    }

    func testHashInsideTextIsNotAHeading() {
        // "#######" is too deep, and "#tag" has no space, so neither is a heading.
        let kinds = DSHMarkdown.blocks(from: "#tag\n####### nope").map(\.kind)
        XCTAssertEqual(kinds.count, 1, "both lines belong to one paragraph")
        guard case .paragraph = kinds[0] else { return XCTFail("expected paragraph") }
    }

    func testTableSeparatorIsRequired() {
        // A pipe line with no separator row is prose, not a table.
        let kinds = DSHMarkdown.blocks(from: "| not | a table |").map(\.kind)
        guard case .paragraph = kinds[0] else { return XCTFail("expected paragraph") }
    }

    func testNumberOfListItemKeepsItsOwnNumberingOrder() {
        let kinds = DSHMarkdown.blocks(from: "1. one\n2. two").map(\.kind)
        guard case .numbers(let items) = kinds[0] else { return XCTFail("expected numbers") }
        XCTAssertEqual(items, ["one", "two"])
    }

}


/// Intercepts requests so the Relay HTTP calls can be asserted without a server.
final class DSHStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let handler = Self.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let (status, data) = handler(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

#if canImport(UIKit)
import UIKit
import SwiftUI

@MainActor
final class DSHConversationViewportTests: XCTestCase {
    func testSkillSuggestionsUsePromptPathAndHostCommandsWinNameCollisions() throws {
        let catalog = try JSONDecoder().decode(DSHCommandCatalog.self, from: Data(#"{"sessionId":"s","commands":[{"name":"review","description":"Host"}],"skills":[{"name":"review","description":"Skill duplicate","modelInvocable":true},{"name":"write-docs","description":"Docs","modelInvocable":false}]}"#.utf8))
        let choices = dshComposerCommands(catalog)
        XCTAssertEqual(choices.map(\.id), ["review", "write-docs"])
        XCTAssertEqual(choices[0].gloss, "Host")
        XCTAssertNil(dshNativeComposerCommand("/write-docs", knownCommands: Set(catalog.commands.map(\.name))))
    }
    func testComposerRoutesOnlyExactPlanAndGoalCommands() {
        XCTAssertEqual(dshNativeComposerCommand("  /plan 修复问题  "), "/plan 修复问题")
        XCTAssertEqual(dshNativeComposerCommand("/plan"), "/plan")
        XCTAssertEqual(dshNativeComposerCommand("/goal\n长期目标"), "/goal\n长期目标")
        XCTAssertNil(dshNativeComposerCommand("/planet"))
        XCTAssertNil(dshNativeComposerCommand("解释 /plan"))
        XCTAssertNil(dshNativeComposerCommand("/other test"))
        XCTAssertEqual(dshNativeComposerCommand("/custom task", knownCommands: ["custom"]), "/custom task")
        XCTAssertNil(dshNativeComposerCommand("/plan task", knownCommands: []))
        XCTAssertNil(dshNativeComposerCommand("/customized", knownCommands: ["custom"]))
    }

    func testPlanReviewIntentSurvivesQuestionDecoding() throws {
        let data = Data(##"{"id":"review","question":"Approve?","detail":"# Plan","options":[{"label":"Yes"},{"label":"No"}],"intent":{"kind":"plan-review","approve":"Yes"}}"##.utf8)
        let question = try JSONDecoder().decode(DSHQuestion.self, from: data)
        XCTAssertEqual(question.intent?.approve, "Yes")
        XCTAssertEqual(question.detail, "# Plan")
        let legacy = try JSONDecoder().decode(DSHQuestion.self, from: Data(#"{"id":"q","question":"Why?"}"#.utf8))
        XCTAssertNil(legacy.intent)
    }
    func testHeaderTranslucentTextAppearance() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView:
            ZStack(alignment: .top) {
                Color(.systemBackground).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<18) { _ in
                        Text("这是一段经过顶部的聊天文字 ABC 123")
                            .font(.system(size: 20))
                    }
                }.padding(.horizontal, 16)
                DSHHeaderBackdrop()
                    .frame(height: 110)
            })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(400))
            window.layoutIfNeeded()
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            })
            attachment.name = style == .dark ? "header-translucent-dark" : "header-translucent-light"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testKeyboardAndComposerResizeKeepTailVisible() async {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        scroll.contentSize = CGSize(width: 390, height: 1800)
        let coordinator = DSHScrollCoordinator()
        coordinator.attach(scroll)
        await settle()
        XCTAssertEqual(scroll.contentOffset.y, 1100, accuracy: 0.5)
        scroll.frame.size.height = 350
        await settle()
        XCTAssertTrue(coordinator.isFollowingLatest)
        XCTAssertEqual(scroll.contentOffset.y, 1450, accuracy: 0.5)
        scroll.contentSize.height = 2000
        await settle()
        XCTAssertEqual(scroll.contentOffset.y, 1650, accuracy: 0.5)
        scroll.frame.size.height = 700
        await settle()
        XCTAssertEqual(scroll.contentOffset.y, 1300, accuracy: 0.5)
    }

    func testHistoryReaderIsNotPulledToBottomByResizeOrStreaming() async {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        scroll.contentSize = CGSize(width: 390, height: 1800)
        let coordinator = DSHScrollCoordinator()
        coordinator.attach(scroll)
        await settle()
        scroll.contentOffset.y = 400
        coordinator.userDidScroll()
        XCTAssertFalse(coordinator.isFollowingLatest)
        scroll.frame.size.height = 350
        scroll.contentSize.height = 2200
        await settle()
        XCTAssertEqual(scroll.contentOffset.y, 400, accuracy: 0.5)
        coordinator.resumeFollowing()
        await settle()
        XCTAssertEqual(scroll.contentOffset.y, 1850, accuracy: 0.5)
    }

    func testGlassInsetsKeepTailVisibleWithoutChangingScrollFrame() async {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        scroll.contentSize = CGSize(width: 390, height: 1800)
        let coordinator = DSHScrollCoordinator()
        coordinator.attach(scroll)
        await settle()
        scroll.contentInset = UIEdgeInsets(top: 58, left: 0, bottom: 76, right: 0)
        await settle()
        XCTAssertEqual(scroll.contentOffset.y, 1176, accuracy: 0.5)
        scroll.contentInset.bottom = 420
        await settle()
        XCTAssertEqual(scroll.contentOffset.y, 1520, accuracy: 0.5)
        scroll.contentOffset.y = 400
        coordinator.userDidScroll()
        scroll.contentInset.bottom = 76
        await settle()
        XCTAssertEqual(scroll.contentOffset.y, 400, accuracy: 0.5)
    }

    func testShortTranscriptRespectsTopInset() async {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        scroll.contentSize = CGSize(width: 390, height: 100)
        scroll.contentInset.top = 12
        let coordinator = DSHScrollCoordinator()
        coordinator.attach(scroll)
        await settle()
        XCTAssertEqual(scroll.contentOffset.y, -12, accuracy: 0.5)
    }

    func testReasoningNeedleTracksArcEndpointInSameDirection() {
        let intensities = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
        let angles = intensities.map { DSHReasoningGlyphMetrics.angle(for: $0) }
        XCTAssertEqual(angles.first, 135)
        XCTAssertEqual(angles.last, 330)
        XCTAssertEqual(angles, angles.sorted())
        for intensity in intensities {
            XCTAssertEqual(DSHReasoningGlyphMetrics.angle(for: intensity),
                           DSHReasoningGlyphMetrics.arcEnd(for: intensity) * 360, accuracy: 0.001)
        }
    }

    func testReasoningRailEndpointsAndHitTestingStayAligned() {
        for width in [CGFloat(250), 302, 360] {
            let rail = DSHReasoningRailMetrics(width: width)
            XCTAssertEqual(rail.x(for: 0) - rail.knobDiameter / 2, rail.outerInset)
            XCTAssertEqual(rail.x(for: 1) + rail.knobDiameter / 2, width - rail.outerInset)
            for count in 2...7 {
                for index in 0..<count {
                    let x = rail.x(for: CGFloat(index) / CGFloat(count - 1))
                    XCTAssertEqual(rail.index(for: x, lastIndex: count - 1), index)
                }
                XCTAssertEqual(rail.index(for: -50, lastIndex: count - 1), 0)
                XCTAssertEqual(rail.index(for: width + 50, lastIndex: count - 1), count - 1)
            }
        }
    }

    func testReasoningGlyphDoesNotChangeWithCatalogSubset() {
        let subset = ["low", "medium", "high"].map { DSHModelReasoningEffort(id: $0, name: $0) }
        let full = ["none", "minimal", "low", "medium", "high", "xhigh"].map { DSHModelReasoningEffort(id: $0, name: $0) }
        XCTAssertEqual(dshReasoningIntensity(subset, selectedEffortID: "high"),
                       dshReasoningIntensity(full, selectedEffortID: "high"))
        XCTAssertEqual(dshReasoningIntensity(full, selectedEffortID: "none"), 0)
        XCTAssertEqual(dshReasoningIntensity(full, selectedEffortID: "xhigh"), 1)
        XCTAssertEqual(dshOrderedReasoningEfforts(full.reversed()).map(\.id), full.map(\.id))
        XCTAssertEqual(dshNearestReasoningEffortIndex(full, to: "ultra"), 5)
    }

    func testLongConversationViewportStaysBetweenHeaderAndComposer() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        let model = DSHAppModel.preview(longConversation: true)
        model.collapseComposerControls = true
        let host = UIHostingController(rootView: NavigationStack {
            ConversationView(sessionID: "preview-session").environmentObject(model)
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(800))
        window.layoutIfNeeded()
        // Pinning is deliberately deferred out of layout. Drain that main
        // queue work before measuring the post-layout viewport.
        await settle()
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let allViews = descendants(host.view)
        let scroll = try XCTUnwrap(allViews.compactMap { $0 as? UIScrollView }
            .max { $0.bounds.height < $1.bounds.height })
        let editor = try XCTUnwrap(allViews.first { $0 is UITextField || $0 is UITextView })
        func assertViewport(file: StaticString = #filePath, line: UInt = #line) {
            let viewport = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: window)
            let underlay = scroll.convert(scroll.bounds, to: window)
            let editorRect = editor.convert(editor.bounds, to: window)
            // Preserve the glass backdrop: the raw scroll surface must extend
            // behind both controls, while the unobscured viewport stays inside.
            XCTAssertLessThan(underlay.minY, viewport.minY, file: file, line: line)
            XCTAssertGreaterThan(underlay.maxY, editorRect.minY, file: file, line: line)
            XCTAssertGreaterThanOrEqual(viewport.minY, window.safeAreaInsets.top + 55, file: file, line: line)
            XCTAssertLessThanOrEqual(viewport.maxY, editorRect.minY, file: file, line: line)
            let bottom = max(-scroll.adjustedContentInset.top,
                             scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 3, file: file, line: line)
        }
        func capture(_ name: String) {
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let attachment = XCTAttachment(image: renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            })
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // Lazy transcript rows can change contentSize after the first layout
        // pass, particularly on a busy CI simulator. Wait for the coordinator
        // to follow the resulting size change before evaluating the viewport.
        func waitForPinnedViewport() async throws {
            for _ in 0..<100 {
                let bottom = max(-scroll.adjustedContentInset.top,
                                 scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                if abs(scroll.contentOffset.y - bottom) <= 3 { return }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await waitForPinnedViewport()
        assertViewport()
        capture("conversation-bottom")
        let oldHeight = scroll.bounds.inset(by: scroll.adjustedContentInset).height
        XCTAssertTrue(editor.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(800))
        window.layoutIfNeeded()
        // Pinning is deliberately deferred out of layout. Drain that main
        // queue work before measuring the post-layout viewport.
        await settle()
        try await waitForPinnedViewport()
        assertViewport()
        XCTAssertLessThan(scroll.bounds.inset(by: scroll.adjustedContentInset).height, oldHeight)
        capture("conversation-composer-expanded")
        // Exercise a keyboard-sized safe-area change independently of the
        // simulator's hardware/software keyboard setting. Dismiss the real
        // keyboard first: UIKit overlaps these insets rather than adding them.
        editor.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(800))
        window.layoutIfNeeded()
        // Pinning is deliberately deferred out of layout. Drain that main
        // queue work before measuring the post-layout viewport.
        await settle()
        let expandedHeight = scroll.bounds.inset(by: scroll.adjustedContentInset).height
        host.additionalSafeAreaInsets.bottom = 320
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        // Pinning is deliberately deferred out of layout. Drain that main
        // queue work before measuring the post-layout viewport.
        await settle()
        try await waitForPinnedViewport()
        assertViewport()
        XCTAssertLessThan(scroll.bounds.inset(by: scroll.adjustedContentInset).height, expandedHeight - 250)
        capture("conversation-keyboard-sized-inset")
        host.additionalSafeAreaInsets.bottom = 0
        editor.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(500))
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        window.layoutIfNeeded()
        // Pinning is deliberately deferred out of layout. Drain that main
        // queue work before measuring the post-layout viewport.
        await settle()
        capture("conversation-top")
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height / 2), animated: false)
        window.layoutIfNeeded()
        // Pinning is deliberately deferred out of layout. Drain that main
        // queue work before measuring the post-layout viewport.
        await settle()
        capture("conversation-glass-scrolled")
    }

    // Opt-in visual acceptance fixture, recorded with simctl. Keep the real
    // conversation chrome and move the same text through the native top edge.
    func testProgressiveTopEdgeSlowScrollPreview() async throws {
        guard ProcessInfo.processInfo.environment["DSH_RECORD_SCROLL_PREVIEW"] == "1" else {
            throw XCTSkip("Enable DSH_RECORD_SCROLL_PREVIEW to record the slow-scroll preview")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let model = DSHAppModel.preview(longConversation: true)
            model.collapseComposerControls = true
            let host = UIHostingController(rootView: NavigationStack {
                ConversationView(sessionID: "preview-session").environmentObject(model)
            })
            window.overrideUserInterfaceStyle = style
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(800))
            window.layoutIfNeeded()
            await settle()
            let scroll = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIScrollView }
                .max { $0.bounds.height < $1.bounds.height })
            // Programmatic scrolling does not produce a user pan. Disarm the
            // existing follow coordinator exactly as a reader's drag would.
            let probe = try XCTUnwrap(descendants(host.view).compactMap { $0 as? DSHScrollProbeView }.first)
            try XCTUnwrap(probe.coordinator).pauseFollowing()
            await settle()
            let lower = max(-scroll.adjustedContentInset.top, scroll.contentSize.height / 2 - 250)
            let upper = min(lower + 500, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            XCTAssertGreaterThan(upper - lower, 300)
            scroll.setContentOffset(CGPoint(x: 0, y: lower), animated: false)
            try await Task.sleep(for: .milliseconds(500))
            let headerInset = scroll.adjustedContentInset.top
            for forward in [true, false] {
                for step in 0...120 {
                    let progress = CGFloat(step) / 120
                    let y = forward ? lower + (upper - lower) * progress : upper - (upper - lower) * progress
                    scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                    try await Task.sleep(for: .milliseconds(50))
                    XCTAssertEqual(scroll.contentOffset.y, y, accuracy: 1)
                    XCTAssertEqual(scroll.adjustedContentInset.top, headerInset, accuracy: 0.5)
                    if forward && step == 60 {
                        let shot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        })
                        shot.name = "native-edge-slow-scroll-\(style == .dark ? "dark" : "light")"
                        shot.lifetime = .keepAlways
                        add(shot)
                    }
                }
            }
        }
    }
}
#endif

#if canImport(UIKit)
@MainActor
private final class DSHHomeSearchFixture: ObservableObject {
    @Published var text = ""
    @Published var searching = true
}

private struct DSHHomeSearchFixtureView: View {
    @ObservedObject var fixture: DSHHomeSearchFixture
    var body: some View {
        Color(.systemBackground)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                DSHHomeBottomBar(searchText: $fixture.text, isSearching: $fixture.searching, onNewTask: {})
                    .padding(.bottom, 8)
            }
    }
}

@MainActor
final class DSHHomeLayoutTests: XCTestCase {
    func testArchivedTasksStaySeparateAndSearchableWithoutAProject() {
        let sessions = [
            DSHSessionSummary(id: "active", title: "Active", updatedAt: 40, workspaceName: "Project"),
            DSHSessionSummary(id: "older", title: "Finished", updatedAt: 10, workspaceName: "Project", archived: true),
            DSHSessionSummary(id: "unfiled", title: "Detached", updatedAt: 30, archived: true),
            DSHSessionSummary(id: "recent", title: "Recent", updatedAt: 20, workspaceName: "Project", archived: true)
        ]
        let active = sessions.groupedForList(.byWorkspace, showArchived: false).flatMap(\.sessions)
        let archived = dshArchivedSessionsForHome(sessions)
        XCTAssertEqual(active.map(\.id), ["active"])
        XCTAssertEqual(archived.map(\.id), ["unfiled", "recent", "older"])
        XCTAssertTrue(Set(active.map(\.id)).isDisjoint(with: Set(archived.map(\.id))))
        XCTAssertEqual(dshArchivedSessionsForHome(sessions, matching: "  detached  ").map(\.id), ["unfiled"])
        XCTAssertEqual(dshArchivedSessionsForHome(sessions, matching: "project").map(\.id), ["recent", "older"])
        XCTAssertTrue(dshArchivedSessionsForHome(sessions, matching: "missing").isEmpty)
    }

    func testWorkspacePickerHidesDotFoldersWithoutChangingRemotePaths() {
        let directories = [
            DSHDirectoryEntry(name: ".git", path: "/Mac/.git"),
            DSHDirectoryEntry(name: "Project", path: "/Mac/Project"),
            DSHDirectoryEntry(name: ".config", path: "/Mac/.config"),
            DSHDirectoryEntry(name: "project.v2", path: "/Mac/project.v2")
        ]
        XCTAssertEqual(dshVisibleWorkspaceDirectories(directories).map(\.path), ["/Mac/Project", "/Mac/project.v2"])
        XCTAssertTrue(dshVisibleWorkspaceDirectories([directories[0]]).isEmpty)
    }

    func testHomeArchiveSectionAndChatAppearance() async throws {
        var state = DSHStoreState()
        state.hasLoadedSessions = true
        state.sessions = [
            DSHSessionSummary(id: "active", title: "正在进行的任务", updatedAt: 30, workspaceId: "work", workspaceName: "工作项目"),
            DSHSessionSummary(id: "archived", title: "已完成的归档任务", updatedAt: 20, workspaceId: "work", workspaceName: "工作项目", archived: true),
            DSHSessionSummary(id: "archived-unfiled", title: "无项目的归档任务", updatedAt: 10, archived: true)
        ]
        state.workspaceCatalog = [DSHWorkspaceOption(id: "work", name: "工作项目")]
        let model = DSHAppModel(transport: DSHPreviewTransport(), initialState: state, isPaired: true)
        model.groupsSessionsByWorkspace = true
        model.showArchivedSessions = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: DSHRemoteHomeView().environmentObject(model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(600))
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            })
            attachment.name = "home-archive-\(style == .light ? "light" : "dark")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testSearchDockMatchesConversationAndTracksKeyboardSafeArea() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        let model = DSHAppModel.preview()
        model.showUsageFooter = false
        model.draft = ""
        let host = UIHostingController(rootView: AnyView(NavigationStack {
            ConversationView(sessionID: "preview-session").environmentObject(model)
        }))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func capture(_ name: String) {
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            })
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        try await Task.sleep(for: .milliseconds(650))
        let conversationField = try XCTUnwrap(descendants(host.view).first { $0 is UITextField || $0 is UITextView })
        let conversationCenter = conversationField.convert(conversationField.bounds, to: window).midY
        let fixture = DSHHomeSearchFixture()
        host.rootView = AnyView(DSHHomeSearchFixtureView(fixture: fixture))
        try await Task.sleep(for: .milliseconds(650))
        let search = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextField }.first)
        let searchRect = search.convert(search.bounds, to: window)
        XCTAssertEqual(search.returnKeyType, .search)
        XCTAssertTrue(search.isFirstResponder)
        XCTAssertGreaterThan(search.bounds.width, window.bounds.width * 0.6)
        XCTAssertLessThanOrEqual(searchRect.midY, conversationCenter + 3)
        capture("home-search-expanded")
        // Compare like-for-like keyboard states. The search field focuses on
        // entry, while the conversation field above was unfocused. UIKit also
        // takes max(keyboard, additional safe-area) rather than adding them.
        search.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(800))
        window.layoutIfNeeded()
        let unfocusedRect = search.convert(search.bounds, to: window)
        XCTAssertEqual(unfocusedRect.midY, conversationCenter, accuracy: 3)
        host.additionalSafeAreaInsets.bottom = 320
        try await Task.sleep(for: .milliseconds(350))
        window.layoutIfNeeded()
        let raisedRect = search.convert(search.bounds, to: window)
        XCTAssertEqual(unfocusedRect.midY - raisedRect.midY, 320, accuracy: 2)
        capture("home-search-keyboard-inset")
        fixture.searching = false
        host.additionalSafeAreaInsets.bottom = 0
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(descendants(host.view).compactMap { $0 as? UITextField }.isEmpty)
        capture("home-dock-aligned")
    }

    func testNewTaskRightSwipeDistinguishesReturnFromScrollingAndControlDrags() {
        XCTAssertTrue(dshShouldDismissNewTaskForRightSwipe(
            translation: CGSize(width: 150, height: 12), predictedEndTranslation: CGSize(width: 220, height: 16)))
        XCTAssertFalse(dshShouldDismissNewTaskForRightSwipe(
            translation: CGSize(width: -150, height: 12), predictedEndTranslation: CGSize(width: -220, height: 16)))
        XCTAssertFalse(dshShouldDismissNewTaskForRightSwipe(
            translation: CGSize(width: 110, height: 180), predictedEndTranslation: CGSize(width: 140, height: 220)))
        XCTAssertFalse(dshShouldDismissNewTaskForRightSwipe(
            translation: CGSize(width: 30, height: 2), predictedEndTranslation: CGSize(width: 45, height: 2)))
    }

    func testSettingsAndRemoteHomeUseSingleLayout() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        let model = DSHAppModel.preview()
        model.selectedSessionID = nil
        let host = UIHostingController(rootView: SettingsView()
            .environmentObject(model)
            .environment(\.locale, Locale(identifier: "zh-Hans")))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(600))
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap(descendants)
        }
        XCTAssertTrue(descendants(host.view).compactMap { $0 as? UISegmentedControl }.isEmpty)
        func capture(_ name: String) {
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let attachment = XCTAttachment(image: renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            })
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture("settings-neutral")
        let root = UIHostingController(rootView: DSHRootView().environmentObject(model))
        window.rootViewController = root
        try await Task.sleep(for: .milliseconds(600))
        capture("remote-home-restored")

    }
}
#endif

#if canImport(UIKit)
// Opt-in live integration: the fixture endpoint must belong to an isolated
// DSH_HOME and Relay. Ordinary test runs never contact a developer's Harness.
extension DSHModelPanelLayoutTests {
    @MainActor
    func testIsolatedNativeHarnessThroughRealRelayTransport() async throws {
        guard let address = ProcessInfo.processInfo.environment["DSH_PARITY_FIXTURE_URL"],
              let url = URL(string: address), url.host == "127.0.0.1" else {
            throw XCTSkip("Set DSH_PARITY_FIXTURE_URL for the isolated Native integration stack")
        }
        struct Fixture: Decodable { let relayURL: URL; let machineId: String; let pairingSecret: String; let sessionId: String; let workspace: String }
        let (data, _) = try await URLSession.shared.data(from: url)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        guard fixture.relayURL.host == "127.0.0.1", fixture.relayURL.scheme == "http" else {
            throw XCTSkip("Native integration requires an isolated loopback Relay")
        }
        let api = DSHAPIClient(relayBaseURL: fixture.relayURL)
        let pairing = try await api.pair(machineId: fixture.machineId, credential: .secret(fixture.pairingSecret), deviceName: "iOS Native parity integration")
        let suite = "dsh-live-parity-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let profileStore = DSHProfileStore(defaults: defaults)
        profileStore.upsert(pairing.profile)
        let keychain = DSHKeychainTokenStore(service: suite)
        try keychain.save(pairing.token, account: pairing.profile.deviceId)
        let transport = DSHRemoteTransport(tokenStore: keychain, store: profileStore)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = DSHAppModel(transport: transport, isPaired: true, transactionDirectory: directory, profileStore: profileStore)
        model.machineID = fixture.machineId
        addTeardownBlock {
            await MainActor.run { model.disconnect() }
            await transport.disconnect()
            try await api.revokeSelfDevice(machineId: fixture.machineId, token: pairing.token)
            try keychain.delete(account: pairing.profile.deviceId)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        func until(_ description: String, _ condition: () -> Bool) async throws {
            for _ in 0..<400 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("Native integration did not settle: \(description); state=\(model.connectionState), sessions=\(model.sessions.count), machine=\(model.machineID); \(model.errorMessage ?? "no app error")")
            throw URLError(.timedOut)
        }
        try await Task.sleep(for: .milliseconds(150))
        model.connect()
        try await until("connected session snapshot") { model.connectionState == .connected && model.hasLoadedSessions }
        let title = "iOS 原生联调 \(UUID().uuidString.prefix(6))"
        XCTAssertTrue(model.createSession(title: title, workingDirectory: fixture.workspace, permissionMode: "read-only"))
        try await until("phone-created Native session") { model.sessions.contains { $0.title == title } }
        let sessionID = try XCTUnwrap(model.sessions.first { $0.title == title }?.id)
        model.openSession(sessionID)
        try await until("dynamic Native commands") { model.commandCatalog(for: sessionID) != nil }
        let catalog = try XCTUnwrap(model.commandCatalog(for: sessionID))
        XCTAssertTrue(catalog.commands.contains { $0.name == "plan" })
        let settings = try await model.readConfiguration("settings").decoded(DSHSettingsSnapshot.self)
        XCTAssertTrue(settings.writable); XCTAssertGreaterThan(settings.namespaces.count, 10)
        let plugins = try await model.readConfiguration("plugins").decoded(DSHPluginInventory.self)
        XCTAssertFalse(plugins.entries.isEmpty)
        let providers = try await model.readConfiguration("providers").decoded(DSHProviderDirectory.self)
        XCTAssertFalse(providers.configurable.isEmpty)
        let theme = try XCTUnwrap(settings.namespaces.first { $0.ns == "ui-theme" })
        let change = model.configurationCommand(payload: .object(["kind": .string("settings"), "ns": .string(theme.ns),
            "expectedRevision": .number(Double(theme.revision)), "ops": .array([.object(["op": .string("set"), "path": .array([.string("preference")]), "value": .string("dark")])])]))
        let receipt = try await model.updateConfiguration(change)
        XCTAssertEqual(receipt.namespace?.value.executionObject["preference"], .string("dark"))
        let repeated = try await model.updateConfiguration(change)
        XCTAssertEqual(repeated, receipt)
        let latest = try XCTUnwrap(receipt.namespace)
        let clear = model.configurationCommand(payload: .object(["kind": .string("settings"), "ns": .string(theme.ns),
            "expectedRevision": .number(Double(latest.revision)), "ops": .array([.object(["op": .string("unset"), "path": .array([.string("preference")])])])]))
        _ = try await model.updateConfiguration(clear)
        let files = try await model.workspaceFiles(sessionID: sessionID, path: "")
        XCTAssertTrue(files.entries.contains { $0.name == "手机联调说明.txt" })
        let ref = DSHFileReference(sessionID: sessionID, path: fixture.workspace + "/手机联调说明.txt", name: "手机联调说明.txt")
        let downloaded = try await model.downloadFile(ref)
        XCTAssertEqual(try String(contentsOf: downloaded, encoding: .utf8), "手机与桌面使用同一份 Harness 原生数据。\n文件完整读取与中文路径验证。\n")
        try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent())
        if let mockAddress = ProcessInfo.processInfo.environment["DSH_PARITY_MOCK_MODEL_URL"],
           let mockURL = URL(string: mockAddress), mockURL.host == "127.0.0.1", mockURL.scheme == "http" {
            var mockRequest = URLRequest(url: mockURL.appendingPathComponent("control"))
            mockRequest.httpMethod = "POST"
            mockRequest.httpBody = Data(#"{"scenario":"plain"}"#.utf8)
            let (_, response) = try await URLSession.shared.data(for: mockRequest)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let contents = Data("真实手机附件联调\n保留完整内容。\n".utf8)
            let attachment = DSHStagedAttachment(name: "手机附件.txt", data: contents, isImage: false)
            let sent = try await model.sendStagedPromptPersisted("请读取这份测试附件", attachments: [attachment],
                to: sessionID, requestId: "native-attachment-\(UUID().uuidString)")
            XCTAssertTrue(sent)
            try await until("Native attachment persisted") {
                model.messages(for: sessionID).contains { $0.role == .user && $0.nativeSequence != nil && $0.attachments.contains { $0.name == attachment.name && $0.hostPath != nil } }
            }
            let message = try XCTUnwrap(model.messages(for: sessionID).first { $0.role == .user && $0.nativeSequence != nil && $0.attachments.contains { $0.name == attachment.name } })
            let history = try await model.historyPage(sessionID: sessionID, atSeq: message.nativeSequence)
            let row = try XCTUnwrap(history.rows.first { $0.type == "user.message.accepted" && $0.nativeSequence == message.nativeSequence })
            let payload = try XCTUnwrap(row.payload["attachments"])
            let replayed = try JSONDecoder().decode([DSHMessageAttachment].self, from: JSONEncoder().encode(payload))
            let persisted = try XCTUnwrap(replayed.first { $0.name == attachment.name && $0.hostPath != nil })
            let storedRef = try XCTUnwrap(persisted.fileReference(sessionID: sessionID))
            let stored = try await model.downloadFile(storedRef)
            XCTAssertEqual(try Data(contentsOf: stored), contents)
            try? FileManager.default.removeItem(at: stored.deletingLastPathComponent())
            let previewScene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previewWindow = UIWindow(windowScene: previewScene)
            let preview = UIHostingController(rootView: DSHRemoteFilePreview(reference: storedRef).environmentObject(model))
            previewWindow.rootViewController = preview
            previewWindow.makeKeyAndVisible()
            defer { previewWindow.isHidden = true }
            func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
            func shareControl() -> UIControl? {
                views(preview.view).compactMap { $0 as? UIControl }.first { $0.accessibilityLabel == "分享或存储" }
            }
            try await until("Native attachment preview share action") { shareControl() != nil }
            try XCTUnwrap(shareControl()).sendActions(for: .touchUpInside)
            func activityController(_ controller: UIViewController) -> UIActivityViewController? {
                if let activity = controller as? UIActivityViewController { return activity }
                if let presented = controller.presentedViewController, let activity = activityController(presented) { return activity }
                return controller.children.compactMap(activityController).first
            }
            try await until("System share sheet presented") {
                guard let activity = activityController(preview) else { return false }
                return activity.viewIfLoaded?.window != nil && !activity.isBeingPresented && activity.transitionCoordinator == nil
            }
            let shareShot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: previewWindow.bounds).image { _ in
                previewWindow.drawHierarchy(in: previewWindow.bounds, afterScreenUpdates: true)
            })
            shareShot.name = "live-native-attachment-system-share"; shareShot.lifetime = .keepAlways; add(shareShot)
            activityController(preview)?.dismiss(animated: false)
        }
        model.requestSubagents(for: sessionID)
        model.requestGoalState(for: sessionID)
        try await until("Native child and goal baseline") { model.subagentCatalog(for: sessionID) != nil && model.goalState(for: sessionID) != nil }
        XCTAssertNil(model.goalState(for: sessionID)?.goal)
        model.executeCommand("/plan", for: sessionID)
        try await until("Native plan command result") { model.commandResults(for: sessionID).contains { $0.matched && $0.kind == "success" } }
        let page = try await model.executionPage(sessionID: sessionID)
        XCTAssertNotNil(page.lifecycle)
        XCTAssertTrue(model.planState(for: sessionID)?.active == true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene), window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.rootViewController = UIHostingController(rootView: NavigationStack { DSHComputerConfigurationView().environmentObject(model) }.dynamicTypeSize(dark ? .accessibility2 : .large))
            window.makeKeyAndVisible(); try await Task.sleep(for: .milliseconds(1000))
            let shot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
            shot.name = "live-native-configuration-\(dark ? "dark-large-text" : "light")"; shot.lifetime = .keepAlways; add(shot)
        }
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.rootViewController = UIHostingController(rootView: DSHGoalCreationView(sessionID: sessionID).environmentObject(model).dynamicTypeSize(dark ? .accessibility2 : .large).frame(width: 320))
            window.makeKeyAndVisible(); try await Task.sleep(for: .milliseconds(500))
            let shot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
            shot.name = "live-native-goal-create-\(dark ? "dark-large-text" : "light")"; shot.lifetime = .keepAlways; add(shot)
        }
        // Native creation uses the goal endpoint independently of whether
        // a profile registers the optional slash command, and keeps exact refs.
        try await model.createGoal(in: sessionID, objective: "验证手机与桌面共享目标状态", maxGoalRounds: 7)
        try await until("Native created goal") { model.goalState(for: sessionID)?.goal?.maxGoalRounds == 7 }
        let createdGoal = try XCTUnwrap(model.goalState(for: sessionID)?.goal)
        try await model.updateGoal(createdGoal, in: sessionID, action: "pause")
        try await until("Native paused goal") { model.goalState(for: sessionID)?.goal?.phase == "paused" }
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.rootViewController = UIHostingController(rootView: DSHGoalCreationView(sessionID: sessionID).environmentObject(model).dynamicTypeSize(dark ? .accessibility2 : .large).frame(width: 320))
            window.makeKeyAndVisible(); try await Task.sleep(for: .milliseconds(500))
            let shot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
            shot.name = "live-native-goal-manage-\(dark ? "dark-large-text" : "light")"; shot.lifetime = .keepAlways; add(shot)
        }
        let pausedGoal = try XCTUnwrap(model.goalState(for: sessionID)?.goal)
        try await model.updateGoal(pausedGoal, in: sessionID, action: "edit", objective: "完整目标内容在手机上可阅读", maxGoalRounds: 8)
        try await until("Native edited goal") { model.goalState(for: sessionID)?.goal?.maxGoalRounds == 8 }
        let editedGoal = try XCTUnwrap(model.goalState(for: sessionID)?.goal)
        try await model.updateGoal(editedGoal, in: sessionID, action: "resume")
        try await until("Native resumed goal") { model.goalState(for: sessionID)?.goal?.phase == "active" }
        let resumedGoal = try XCTUnwrap(model.goalState(for: sessionID)?.goal)
        try await model.updateGoal(resumedGoal, in: sessionID, action: "complete")
        try await until("Native completed goal") { model.goalState(for: sessionID)?.goal?.phase == "complete" }
        let completedGoal = try XCTUnwrap(model.goalState(for: sessionID)?.goal)
        try await model.createGoal(in: sessionID, objective: "替换已完成目标并重置轮次", maxGoalRounds: 3)
        try await until("Native replacement of completed goal") { model.goalState(for: sessionID)?.goal?.id != completedGoal.id }
        let replacement = try XCTUnwrap(model.goalState(for: sessionID)?.goal)
        XCTAssertEqual(model.goalState(for: sessionID)?.roundsStarted, 0)
        try await model.updateGoal(replacement, in: sessionID, action: "clear")
        try await until("Native cleared goal") { model.goalState(for: sessionID)?.goal == nil }
        model.disconnect()
        try await until("disconnect") { model.connectionState == .disconnected }
        model.connect()
        try await until("reconnect") { model.connectionState == .connected }
        let restored = try await model.readConfiguration("settings").decoded(DSHSettingsSnapshot.self)
        XCTAssertEqual(restored.namespaces.first { $0.ns == "ui-theme" }?.value.executionObject["preference"], theme.value.executionObject["preference"])
        model.executeCommand("/plan off", for: sessionID)
        try await until("Native plan exit") { model.commandResults(for: sessionID).contains { $0.text?.contains("Plan mode off") == true } }
        if let sourceID = ProcessInfo.processInfo.environment["DSH_PARITY_FORK_SESSION_ID"] {
            model.openSession(sourceID)
            try await until("Native fork source history") { model.messages(for: sourceID).contains { $0.role == .assistant && $0.nativeSequence != nil } }
            let answer = try XCTUnwrap(model.messages(for: sourceID).first { $0.role == .assistant && $0.nativeSequence != nil })
            let childID = try await model.forkSession(sourceID, atSeq: answer.nativeSequence)
            try await until("Native fork remains in ordinary session list") { model.sessions.contains { $0.id == childID } }
            model.openSession(childID)
            try await until("Native fork opens with inherited answer") { model.messages(for: childID).contains { $0.id == answer.id } }
            let childPage = try await model.executionPage(sessionID: childID)
            XCTAssertGreaterThan(childPage.lifecycle?.inheritedEventCount ?? 0, 0)
            XCTAssertEqual(childPage.lifecycle?.turnsStarted, 0)
            XCTAssertEqual(childPage.lifecycle?.endedTurnMilliseconds, 0)
        }
    }
}
#endif

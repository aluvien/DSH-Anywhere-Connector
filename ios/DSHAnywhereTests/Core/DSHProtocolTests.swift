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
        assertViewport()
        capture("conversation-bottom")
        let oldHeight = scroll.bounds.inset(by: scroll.adjustedContentInset).height
        XCTAssertTrue(editor.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(800))
        window.layoutIfNeeded()
        assertViewport()
        XCTAssertLessThan(scroll.bounds.inset(by: scroll.adjustedContentInset).height, oldHeight)
        capture("conversation-composer-expanded")
        // Headless simulators can have a hardware keyboard attached. Exercise
        // a full keyboard-sized safe-area change even when no software keyboard
        // is rendered, independently of the composer's 48-point expansion.
        let expandedHeight = scroll.bounds.inset(by: scroll.adjustedContentInset).height
        host.additionalSafeAreaInsets.bottom = 320
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        assertViewport()
        XCTAssertLessThan(scroll.bounds.inset(by: scroll.adjustedContentInset).height, expandedHeight - 250)
        capture("conversation-keyboard-sized-inset")
        host.additionalSafeAreaInsets.bottom = 0
        editor.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(500))
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        window.layoutIfNeeded()
        capture("conversation-top")
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height / 2), animated: false)
        window.layoutIfNeeded()
        capture("conversation-glass-scrolled")
    }
}
#endif

#if canImport(UIKit)
@MainActor
final class DSHHomeLayoutTests: XCTestCase {
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

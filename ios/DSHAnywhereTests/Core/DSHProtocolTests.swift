import XCTest
@testable import DSHAnywhere

final class DSHProtocolTests: XCTestCase {
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

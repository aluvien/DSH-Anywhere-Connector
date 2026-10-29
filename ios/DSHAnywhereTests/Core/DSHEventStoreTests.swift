import XCTest
@testable import DSHAnywhere

final class DSHEventStoreTests: XCTestCase {
    @MainActor
    func testModelDiscoveryIsRequestScopedAndConfigurationInvalidationsDoNotPersistValues() async throws {
        let restore = installCorrelationTestProfile(); defer { restore() }
        let transport = CorrelationTransport(), model = makeModel(transport: transport, isPaired: true)
        model.connect(); defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(100))
        var discovered: DSHDiscoveredModels?
        let read = Task { discovered = try await model.discoverModels(settingsNs: "llm-test", request: ["apiKey": .string("temporary-test-secret")]) }; defer { read.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        let captured = await transport.lastCommand(ofType: "configuration.discover"), request = try XCTUnwrap(captured)
        let before = model.configurationChangeRevision
        await transport.emit(event(type: "configuration.models", messageID: request.requestId, sequence: 2, payload: .object(["settingsNs": .string("other"), "models": .array([])])))
        await transport.emit(event(type: "configuration.invalidated", messageID: "settings-change", sequence: 3, payload: .object(["section": .string("settings"), "ns": .string("llm-test")])))
        await transport.emit(event(type: "configuration.invalidated", messageID: "credential-change", sequence: 4, payload: .object(["section": .string("credentials"), "ref": .string("TEST_KEY")])))
        try await Task.sleep(for: .milliseconds(100)); XCTAssertNil(discovered)
        XCTAssertEqual(model.configurationChangeRevision, before + 2)
        await transport.emit(event(type: "configuration.models", messageID: request.requestId, sequence: 5, payload: .object(["settingsNs": .string("llm-test"), "models": .array([.object(["id": .string("new")])])])))
        try await read.value
        XCTAssertEqual(discovered?.models.first?.id, "new")
        XCTAssertTrue(model.state.unknownEvents.isEmpty)
        let serialized = String(data: try JSONEncoder().encode(model.state), encoding: .utf8) ?? ""
        XCTAssertFalse(serialized.contains("temporary-test-secret")); XCTAssertFalse(serialized.contains("settings-change"))
    }
    @MainActor
    func testConfigurationConflictRetainsNativeStatusAndReadRepliesStayRequestScoped() async throws {
        let restore = installCorrelationTestProfile(); defer { restore() }
        let transport = CorrelationTransport(), model = makeModel(transport: transport, isPaired: true)
        model.connect(); defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(100))
        let command = model.configurationCommand(payload: .object(["kind": .string("settings"), "ns": .string("llm-test"), "expectedRevision": .number(4), "ops": .array([.object(["op": .string("unset"), "path": .array([.string("baseURL")])])])]))
        let save = Task { try await model.updateConfiguration(command) }; defer { save.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        await transport.emit(event(type: "protocol.error", messageID: command.requestId, sequence: 2, payload: .object(["code": .string("bridge-request-failed"), "message": .string("配置已更新"), "retryable": .bool(false), "httpStatus": .number(409)])))
        do { _ = try await save.value; XCTFail("Expected CAS rejection") } catch let error as DSHConfigurationRequestError { XCTAssertTrue(error.definitelyNotCommitted); XCTAssertEqual(error.failure.httpStatus, 409) }
        var result: DSHConfigurationResult?
        let read = Task { result = try await model.readConfiguration("credentials", refs: ["TEST_KEY"]) }; defer { read.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        let captured = await transport.lastCommand(ofType: "configuration.read"), request = try XCTUnwrap(captured)
        let wrong = DSHJSONValue.object(["section": .string("credentials"), "value": .object(["OTHER_KEY": .object(["configured": .bool(true), "writable": .bool(true)])])])
        await transport.emit(event(type: "configuration.result", messageID: request.requestId, sequence: 3, payload: wrong))
        try await Task.sleep(for: .milliseconds(80)); XCTAssertNil(result)
        await transport.emit(event(type: "configuration.result", messageID: request.requestId, sequence: 4, payload: .object(["section": .string("credentials"), "value": .object(["TEST_KEY": .object(["configured": .bool(false), "writable": .bool(true)])])])) )
        try await read.value
        XCTAssertEqual(result?.value.executionObject.keys.sorted(), ["TEST_KEY"])
    }
    @MainActor
    func testConcurrentConfigurationReadersShareOneWriteAndDoNotUsePlaintextMutationJournal() async throws {
        let restore = installCorrelationTestProfile(); defer { restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("secure-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = CorrelationTransport(), model = makeModel(transport: transport, isPaired: true, transactionDirectory: directory)
        model.connect(); defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(100))
        let command = model.configurationCommand(payload: .object(["kind": .string("credential"), "action": .string("set"), "ref": .string("TEST_KEY"), "value": .string("not-a-real-test-secret")]))
        let first = Task { try await model.updateConfiguration(command) }, second = Task { try await model.updateConfiguration(command) }
        defer { first.cancel(); second.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        let count = await transport.commandCount(ofType: "configuration.update")
        XCTAssertEqual(count, 1)
        let wrong = DSHJSONValue.object(["kind": .string("credential"), "requestId": .string(command.requestId), "ref": .string("OTHER_KEY")])
        await transport.emit(event(type: "configuration.updated", messageID: command.requestId, sequence: 2, payload: wrong))
        try await Task.sleep(for: .milliseconds(70))
        let receipt = DSHJSONValue.object(["kind": .string("credential"), "requestId": .string(command.requestId), "ref": .string("TEST_KEY")])
        await transport.emit(event(type: "configuration.updated", messageID: command.requestId, sequence: 3, payload: receipt))
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a, b)
        XCTAssertTrue(model.state.unknownEvents.isEmpty)
        XCTAssertFalse(String(data: try JSONEncoder().encode(model.state), encoding: .utf8)?.contains("not-a-real-test-secret") == true)
        if let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL] {
            for file in files where file.pathExtension == "json" { XCTAssertFalse((try String(contentsOf: file, encoding: .utf8)).contains("not-a-real-test-secret")) }
        }
    }
    @MainActor
    func testNativeHistoryLocationRequiresTheExactWaiterTargetAndChildAddress() async throws {
        let restore = installCorrelationTestProfile(); defer { restore() }
        let transport = CorrelationTransport(), model = makeModel(transport: transport, isPaired: true)
        model.connect(); defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(100))
        var loaded: DSHHistoryPage?
        let read = Task { loaded = try await model.historyPage(sessionID: "child", atSeq: 0, parentID: "parent", mode: "one-shot") }
        defer { read.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        let captured = await transport.lastCommand(ofType: "history.read"), command = try XCTUnwrap(captured)
        XCTAssertEqual(command.payload.executionObject, ["atSeq": .number(0), "parentSessionId": .string("parent"), "subagentMode": .string("one-shot")])
        func reply(_ requestID: String, _ target: Int, _ sequence: Int64) throws -> DSHEvent {
            let json = "{\"sessionId\":\"child\",\"throughSeq\":1,\"fromSeq\":0,\"toSeq\":1,\"hasMore\":false,\"rows\":[{\"nativeSequence\":0,\"time\":1000,\"type\":\"user.message.accepted\",\"payload\":{\"id\":\"old-message\",\"role\":\"user\",\"markdown\":\"Found\"}}],\"focus\":{\"nativeSequence\":\(target),\"type\":\"user/message\",\"data\":{}}}"
            return DSHEvent(envelope: .init(messageId: requestID, deviceId: "device", machineId: "machine", sessionId: "child", sequence: sequence,
                type: "history.page", payload: try JSONDecoder().decode(DSHJSONValue.self, from: Data(json.utf8))))
        }
        await transport.emit(try reply("other-request", 0, 2))
        await transport.emit(try reply(command.requestId, 1, 3))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(loaded); XCTAssertTrue(model.messages(for: "child").isEmpty)
        await transport.emit(try reply(command.requestId, 0, 4))
        try await read.value
        XCTAssertEqual(loaded?.focus?.nativeSequence, 0)
        XCTAssertEqual(model.messages(for: "child").first?.nativeSequence, 0)
        XCTAssertEqual(model.historyCoverage(for: "child")?.ranges, [.init(lower: 0, upper: 1)])
    }
    func testScheduleProjectionKeepsNewerNativeStateAndRetiresDisconnectedEpochs() throws {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        func apply(_ epoch: String, _ native: Int, _ sequence: Int64, _ items: String = "[]") throws {
            let json = "{\"sessionId\":\"s\",\"epoch\":\"\(epoch)\",\"seq\":\(native),\"available\":true,\"supported\":true,\"items\":\(items)}"
            let payload = try JSONDecoder().decode(DSHJSONValue.self, from: Data(json.utf8))
            XCTAssertTrue(reducer.reduce(DSHEvent(envelope: .init(messageId: "r", deviceId: "d", machineId: "m", sessionId: "s", sequence: sequence, type: "schedule.projection", payload: payload)), into: &state), "A stale read still acknowledges its requesting waiter")
        }
        try apply("old", 4, 1, #"[{"id":"r","kind":"every","prompt":"Check","everySeconds":300,"scheduledAt":"2026-10-30T00:00:00.000Z"}]"#)
        try apply("old", 5, 2)
        try apply("old", 4, 3, #"[{"id":"r","kind":"every","prompt":"Check","everySeconds":300,"scheduledAt":"2026-10-30T00:00:00.000Z"}]"#)
        XCTAssertEqual(state.schedulesBySession?["s"]?.items, [])
        reducer.reduce(DSHEvent(envelope: .init(messageId: "offline", deviceId: "d", machineId: "m", sequence: 0, type: "transport.state", payload: .object(["state": .string("disconnected")]))), into: &state)
        XCTAssertEqual(state.schedulesBySession?["s"]?.available, false)
        try apply("new", -1, 4)
        try apply("old", 20, 5)
        XCTAssertEqual(state.schedulesBySession?["s"]?.epoch, "new")
        XCTAssertEqual(state.schedulesBySession?["s"]?.seq, -1)
    }
    func testNativeHistoryPagesKeepNewestTurnAndLiveStateWithoutRewindingTransport() throws {
        var state = DSHStoreState()
        state.messagesBySession["s"] = [.init(id: "latest-user", role: .user, markdown: "New", nativeSequence: 100)]
        state.turnStateBySession["s"] = "running"
        let reducer = DSHEventReducer()
        func reduce(_ type: String, _ json: String, _ sequence: Int64) throws {
            let payload = try JSONDecoder().decode(DSHJSONValue.self, from: Data(json.utf8))
            reducer.reduce(DSHEvent(envelope: .init(messageId: "r", deviceId: "d", machineId: "m", sessionId: "s", sequence: sequence, type: type, payload: payload)), into: &state)
        }
        try reduce("history.window", #"{"sessionId":"s","throughSeq":99,"fromSeq":90,"toSeq":99,"hasMore":true}"#, 10)
        try reduce("history.page", #"{"sessionId":"s","throughSeq":99,"fromSeq":10,"toSeq":19,"hasMore":true,"rows":[{"nativeSequence":10,"time":1000,"type":"user.message.accepted","payload":{"id":"old-user","role":"user","markdown":"Old"}},{"nativeSequence":11,"time":2000,"type":"assistant.message.completed","payload":{"id":"old-answer","role":"assistant","markdown":"Interrupted","interrupted":true}}]}"#, 11)
        XCTAssertEqual(state.lastSequence, 11)
        XCTAssertEqual(state.turnStateBySession["s"], "running")
        XCTAssertEqual(state.messagesBySession["s"]?.map(\.id), ["old-user", "old-answer", "latest-user"])
        XCTAssertEqual(state.messagesBySession["s"]?[1].interrupted, true)
        XCTAssertNil(state.messagesBySession["s"]?[1].completedAt)
        XCTAssertEqual(state.messagesBySession["s"]?[1].timestamp, 2000)
        XCTAssertEqual(state.historyCoverage?["s"]?.gaps, [.init(lower: 20, upper: 89)])
        XCTAssertEqual(state.historyCoverage?["s"]?.nextBefore, 90)
        let encoded = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(DSHStoreState.self, from: encoded).historyCoverage, state.historyCoverage)
    }

    func testNativeHistoryPageRejectsCrossSessionAndRecursiveRowsAtomically() throws {
        for row in [#"{"nativeSequence":0,"type":"execution.recorded","payload":{"sessionId":"other","record":{"nativeSequence":0,"type":"turn/start","data":{"turn":1}}}}"#,
                    #"{"nativeSequence":0,"type":"history.page","payload":{}}"#] {
            var state = DSHStoreState()
            let json = "{\"sessionId\":\"s\",\"throughSeq\":0,\"fromSeq\":0,\"toSeq\":0,\"hasMore\":false,\"rows\":[\(row)]}"
            let payload = try JSONDecoder().decode(DSHJSONValue.self, from: Data(json.utf8))
            DSHEventReducer().reduce(DSHEvent(envelope: .init(messageId: "r", deviceId: "d", machineId: "m", sessionId: "s", sequence: 1, type: "history.page", payload: payload)), into: &state)
            XCTAssertTrue(state.messagesBySession.isEmpty)
            XCTAssertNil(state.executionBySession)
            XCTAssertNil(state.historyCoverage)
        }
    }

    @MainActor
    func testSearchRepliesAreScopedToTheirRequestQueryAndSession() async throws {
        let restore = installCorrelationTestProfile(); defer { restore() }
        let transport = CorrelationTransport(), model = makeModel(transport: transport, isPaired: true)
        model.connect(); defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(100))
        var result: DSHSearchResults?
        let read = Task { result = try await model.searchHistory(query: "needle") }
        defer { read.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        let captured = await transport.lastCommand(ofType: "session.search"), command = try XCTUnwrap(captured)
        func reply(_ query: String, scope: String? = nil) -> DSHJSONValue {
            var value: [String: DSHJSONValue] = ["query": .string(query), "items": .array([]), "hasMore": .bool(false)]
            if let scope { value["scopeSessionId"] = .string(scope) }
            return .object(value)
        }
        await transport.emit(event(type: "search.results", messageID: command.requestId, sequence: 2, payload: reply("old-query")))
        await transport.emit(event(type: "search.results", messageID: command.requestId, sequence: 3, payload: reply("needle", scope: "other-session")))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(result)
        await transport.emit(event(type: "search.results", messageID: command.requestId, sequence: 4, payload: reply("needle")))
        try await read.value
        XCTAssertEqual(result?.query, "needle")
        XCTAssertNil(result?.scopeSessionId)
    }
    @MainActor
    func testChildImageLocalUpgradeRejectionFinishesImmediatelyAndDoesNotLeaveUnknownDelivery() async throws {
        let restore = installCorrelationTestProfile(); defer { restore() }
        let transport = CorrelationTransport(upgradeRejectedTypes: ["subagent.prompt"]), model = makeModel(transport: transport, isPaired: true)
        _ = await model.preparePromptPersistence(expectedMachineGeneration: model.currentMachineGeneration, expectedMachineID: model.machineID)
        model.connect(); defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        let catalog = try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"parentSessionId":"parent","parentAvailable":true,"entries":[{"kind":"child","id":"child","mode":"continuable","activity":"running","hasChildren":false,"label":"Task"}]}"#.utf8))
        await transport.emit(event(type: "subagent.catalog", messageID: "catalog", sequence: 2, payload: catalog))
        try await Task.sleep(for: .milliseconds(100))
        let images: [DSHJSONValue] = [.object(["type": .string("image"), "mediaType": .string("image/jpeg"), "data": .string("YQ==")])]
        var finished = false
        let first = Task { do { try await model.controlSubagent(childID: "child", parentID: "parent", text: "", images: images); XCTFail("Expected upgrade rejection") }
            catch { XCTAssertTrue(error.localizedDescription.contains("更新 Relay")); finished = true } }
        defer { first.cancel() }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(finished, "A local preflight failure must not wait for the native acknowledgement deadline")
        if !finished { first.cancel() }
        await first.value
        let captured = await transport.lastCommand(ofType: "subagent.prompt"), rejected = try XCTUnwrap(captured)
        let retry = Task { try await model.controlSubagent(childID: "child", parentID: "parent", text: "", images: images) }
        defer { retry.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        let retried = await transport.lastCommand(ofType: "subagent.prompt"), command = try XCTUnwrap(retried)
        XCTAssertNotEqual(command.requestId, rejected.requestId, "A proven unsent request does not need an unknown-outcome tombstone")
        await transport.emit(event(type: "subagent.receipt", messageID: command.requestId, sequence: 3, payload: .object([
            "parentSessionId": .string("parent"), "childSessionId": .string("child"), "requestId": .string(command.requestId), "action": .string("prompt"), "messageId": .string("inbox")])))
        try await retry.value
    }
    @MainActor
    func testImageOnlySubagentPromptRetriesTheSameMultipartCommandAndNeverUsesOrdinaryPrompt() async throws {
        let restore = installCorrelationTestProfile(); defer { restore() }
        let transport = CorrelationTransport(), model = makeModel(transport: transport, isPaired: true)
        _ = await model.preparePromptPersistence(expectedMachineGeneration: model.currentMachineGeneration, expectedMachineID: model.machineID)
        model.connect(); defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        let catalog = try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"parentSessionId":"parent","parentAvailable":true,"entries":[{"kind":"child","id":"child","mode":"continuable","activity":"running","hasChildren":false,"label":"Task"}]}"#.utf8))
        await transport.emit(event(type: "subagent.catalog", messageID: "catalog", sequence: 2, payload: catalog))
        try await Task.sleep(for: .milliseconds(100))
        let images: [DSHJSONValue] = [.object(["type": .string("image"), "mediaType": .string("image/jpeg"), "name": .string("photo.jpg"), "data": .string(Data([0xff, 0xd8, 1]).base64EncodedString())])]
        let first = Task { try await model.controlSubagent(childID: "child", parentID: "parent", text: "", delivery: "steer", images: images) }
        defer { first.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        let captured = await transport.lastCommand(ofType: "subagent.prompt"), command = try XCTUnwrap(captured)
        XCTAssertEqual(command.payload.executionObject["images"], .array(images)); XCTAssertEqual(command.payload.executionObject["text"], .string(""))
        XCTAssertEqual(command.payload.executionObject["parentSessionId"], .string("parent"))
        await transport.emit(event(type: "protocol.error", messageID: command.requestId, sequence: 3,
            payload: .object(["code": .string("bridge-result-unknown"), "message": .string("Unknown image result"), "retryable": .bool(false)])))
        do { try await first.value; XCTFail("Unknown image result must be retained") } catch { }
        let retry = Task { try await model.controlSubagent(childID: "child", parentID: "parent", text: "", delivery: "steer", images: images) }
        defer { retry.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        let retried = await transport.lastCommand(ofType: "subagent.prompt")
        XCTAssertEqual(retried?.requestId, command.requestId); XCTAssertEqual(retried?.payload, command.payload)
        await transport.emit(event(type: "subagent.receipt", messageID: command.requestId, sequence: 4, payload: .object([
            "parentSessionId": .string("parent"), "childSessionId": .string("child"), "requestId": .string(command.requestId), "action": .string("prompt"), "messageId": .string("inbox")])))
        try await retry.value
        let ordinary = await transport.commandCount(ofType: "prompt.send"); XCTAssertEqual(ordinary, 0)
    }
    @MainActor
    func testSubagentImageDraftRestoresExactAddressAndOnlyConsumesConfirmedUnchangedComposition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "subagent-draft-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let address = DSHSubagentDraftAddress(machineID: "m", parentID: "p", childID: "c")
        let first = DSHSubagentComposerDrafts(storage: DSHSubagentMediaStorage(directory: directory), defaults: defaults)
        let image = DSHStagedAttachment(name: "photo.jpg", data: Data([0xff, 0xd8, 1, 2]), isImage: true)
        try await first.load(address)
        first.setText("保留草稿", for: address); first.setDelivery("steer", for: address)
        try await first.setImages([image], for: address)
        let reopened = DSHSubagentComposerDrafts(storage: DSHSubagentMediaStorage(directory: directory), defaults: defaults)
        try await reopened.load(address)
        XCTAssertEqual(reopened.images(for: address), [image]); XCTAssertEqual(reopened.text(for: address), "保留草稿")
        XCTAssertEqual(reopened.delivery(for: address), "steer")
        let other = DSHSubagentDraftAddress(machineID: "m", parentID: "other", childID: "c")
        try await reopened.load(other); XCTAssertTrue(reopened.images(for: other).isEmpty)
        reopened.setText("后来编辑", for: address)
        try await reopened.consume(text: "保留草稿", delivery: "steer", images: [image], address: address)
        XCTAssertEqual(reopened.images(for: address), [image]); XCTAssertEqual(reopened.text(for: address), "后来编辑")
        try await reopened.consume(text: "后来编辑", delivery: "steer", images: [image], address: address)
        XCTAssertTrue(reopened.images(for: address).isEmpty); XCTAssertEqual(reopened.text(for: address), "")
        let afterReceipt = DSHSubagentComposerDrafts(storage: DSHSubagentMediaStorage(directory: directory), defaults: defaults)
        try await afterReceipt.load(address); XCTAssertTrue(afterReceipt.images(for: address).isEmpty)
    }

    @MainActor
    func testConfirmedChildImageTombstoneFencesLeftoverBytesAfterAnotherTextOnlyReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "subagent-receipt-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let storage = DSHSubagentMediaStorage(directory: directory), address = DSHSubagentDraftAddress(machineID: "m", parentID: "p", childID: "c")
        let drafts = DSHSubagentComposerDrafts(storage: storage, defaults: defaults)
        let image = DSHStagedAttachment(name: "photo.jpg", data: Data([1, 2, 3]), isImage: true)
        try await drafts.load(address); try await drafts.setImages([image], for: address)
        try await drafts.consume(text: "", delivery: "queue", images: [image], address: address)
        drafts.setText("new", for: address)
        try await drafts.consume(text: "new", delivery: "queue", images: [], address: address)
        // Simulate bytes left on disk after an interrupted cleanup. A later
        // text-only receipt must not discard the accepted image's identity.
        try await storage.save([image], key: address.key, revision: 100)
        let reopened = DSHSubagentComposerDrafts(storage: DSHSubagentMediaStorage(directory: directory), defaults: defaults)
        try await reopened.load(address)
        XCTAssertTrue(reopened.images(for: address).isEmpty)
    }

    func testSubagentMediaPersistenceRejectsOlderWritesAndBoundsOriginalDraftBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = DSHSubagentMediaStorage(directory: directory)
        let newer = DSHStagedAttachment(name: "new.jpg", data: Data([1]), isImage: true)
        let older = DSHStagedAttachment(name: "old.jpg", data: Data([2]), isImage: true)
        try await storage.save([newer], key: "key", revision: 2)
        try await storage.save([older], key: "key", revision: 1)
        let actual = try await storage.load("key")
        XCTAssertEqual(actual, [newer])
        let oversized = DSHStagedAttachment(name: "large.jpg", data: Data(repeating: 0, count: 6 * 1_024 * 1_024 + 1), isImage: true)
        do { try await storage.save([oversized], key: "key", revision: 3); XCTFail("Oversized media must be rejected") } catch { }
        let after = try await storage.load("key"); XCTAssertEqual(after, [newer])
        try await storage.save([], key: "key", revision: 4)
        let empty = try await storage.load("key"); XCTAssertTrue(empty.isEmpty)
    }
    @MainActor
    func testReferenceQueryRepliesKeepExactRequestKindAndQueryWithoutEnteringChatState() async throws {
        let restore = installCorrelationTestProfile(); defer { restore() }
        let transport = CorrelationTransport(), model = makeModel(transport: transport, isPaired: true)
        model.connect(); defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(80))
        var completed = false
        let task = Task { let result = try await model.referenceCandidates(in: "s", kind: "file", query: "目录/"); completed = true; return result }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(60))
        let captured = await transport.lastCommand(ofType: "reference.list"), command = try XCTUnwrap(captured)
        func payload(_ query: String) -> DSHJSONValue { .object(["sessionId": .string("s"), "kind": .string("file"), "query": .string(query), "items": .array([
            .object(["id": .string("f"), "label": .string("目录/a b.ts"), "kind": .string("file"), "path": .string("目录/a b.ts"), "insertion": .string("@\"目录/a b.ts\"")])])]) }
        await transport.emit(event(type: "reference.candidates", messageID: command.requestId, sequence: 2, payload: payload("old")))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(completed)
        await transport.emit(event(type: "reference.candidates", messageID: command.requestId, sequence: 3, payload: payload("目录/")))
        let result = try await task.value
        XCTAssertEqual(result.items.first?.insertion, "@\"目录/a b.ts\"")
        XCTAssertTrue(model.messages(for: "s").isEmpty)
        XCTAssertTrue(model.state.unknownEvents.isEmpty)
    }
    func testFeedbackNativeWatermarksKeepNewerEditsAndDeletionFromLateSnapshots() throws {
        var state = DSHStoreState(); let reducer = DSHEventReducer()
        func apply(_ type: String, _ json: String, _ seq: Int64) throws {
            reducer.reduce(event(type: type, messageID: "f-\(seq)", sequence: seq,
                payload: try JSONDecoder().decode(DSHJSONValue.self, from: Data(json.utf8))), into: &state)
        }
        try apply("feedback.changed", #"{"sessionId":"s","messageId":"a","nativeSequence":8,"item":{"messageId":"a","rating":"negative","note":"最新备注","version":"v2","createdAt":1,"updatedAt":2}}"#, 1)
        try apply("feedback.state", #"{"sessionId":"s","nativeSequence":7,"items":[]}"#, 2)
        XCTAssertEqual(state.feedbackBySession?["s"]?.items.first?.note, "最新备注")
        try apply("feedback.changed", #"{"sessionId":"s","messageId":"a","nativeSequence":10,"item":null}"#, 3)
        try apply("feedback.changed", #"{"sessionId":"s","messageId":"a","nativeSequence":8,"item":{"messageId":"a","rating":"negative","version":"v2","createdAt":1,"updatedAt":2}}"#, 4)
        XCTAssertTrue(state.feedbackBySession?["s"]?.items.isEmpty == true)
        XCTAssertEqual(state.feedbackBySession?["s"]?.nativeSequence, 10)
    }

    @MainActor
    func testFeedbackReadRejectsAnotherRequestAndOldSnapshotAfterNewLiveEdit() async throws {
        let restore = installCorrelationTestProfile(); defer { restore() }
        let transport = CorrelationTransport(), model = makeModel(transport: transport, isPaired: true)
        model.connect(); defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(80))
        let task = Task { try await model.loadFeedback(for: "s") }; defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(60))
        let captured = await transport.lastCommand(ofType: "feedback.list"), command = try XCTUnwrap(captured)
        let old: DSHJSONValue = .object(["sessionId": .string("s"), "nativeSequence": .number(3), "items": .array([])])
        await transport.emit(event(type: "feedback.state", messageID: "not-mine", sequence: 2, payload: old))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(model.state.feedbackBySession?["s"])
        let live = try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"sessionId":"s","messageId":"a","nativeSequence":9,"item":{"messageId":"a","rating":"positive","version":"new","createdAt":1,"updatedAt":2}}"#.utf8))
        await transport.emit(event(type: "feedback.changed", messageID: "live", sequence: 3, payload: live))
        await transport.emit(event(type: "feedback.state", messageID: command.requestId, sequence: 4, payload: old))
        try await task.value
        XCTAssertEqual(model.feedback(for: "a", in: "s")?.version, "new")
    }

    @MainActor
    func testFeedbackUnknownOutcomeKeepsRequestIdentityAndConfirmedReceiptEndsRetry() async throws {
        let restore = installCorrelationTestProfile(); defer { restore() }
        let transport = CorrelationTransport(), model = makeModel(transport: transport, isPaired: true)
        _ = await model.preparePromptPersistence(expectedMachineGeneration: model.currentMachineGeneration, expectedMachineID: model.machineID)
        model.connect(); defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(80))
        let first = Task { try await model.updateFeedback(messageID: "a", in: "s", action: "put", rating: "negative", note: "保留备注", category: "other", ifVersion: nil) }
        defer { first.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        let captured = await transport.lastCommand(ofType: "feedback.update"), command = try XCTUnwrap(captured)
        XCTAssertEqual(command.payload.executionObject["ifVersion"], .null)
        await transport.emit(event(type: "protocol.error", messageID: command.requestId, sequence: 2,
            payload: .object(["code": .string("bridge-result-unknown"), "message": .string("Unknown feedback result"), "retryable": .bool(false)])))
        do { try await first.value; XCTFail("Unknown result must be reported") } catch { }
        let retry = Task { try await model.updateFeedback(messageID: "a", in: "s", action: "put", rating: "negative", note: "保留备注", category: "other", ifVersion: nil) }
        defer { retry.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        let retried = await transport.lastCommand(ofType: "feedback.update")
        XCTAssertEqual(retried?.requestId, command.requestId)
        let receipt: DSHJSONValue = .object(["sessionId": .string("s"), "messageId": .string("a"), "requestId": .string(command.requestId),
            "item": .object(["messageId": .string("a"), "rating": .string("negative"), "note": .string("保留备注"), "version": .string("v1"), "createdAt": .number(1), "updatedAt": .number(1)])])
        await transport.emit(event(type: "feedback.updated", messageID: command.requestId, sequence: 3, payload: receipt))
        try await retry.value
        let sentPrompts = await transport.commandCount(ofType: "prompt.send")
        XCTAssertEqual(sentPrompts, 0)
    }
    func testSubcallResultReplayPreservesFullOutcomeAndStartTiming() throws {
        var state = DSHStoreState(); let reducer = DSHEventReducer()
        func apply(_ type: String, _ json: String, sequence: Int64) throws {
            let payload = try JSONDecoder().decode(DSHJSONValue.self, from: Data(json.utf8))
            reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: "tool-\(sequence)", deviceId: "device", machineId: "machine", sessionId: "s", sequence: sequence, type: type, payload: payload)), into: &state)
        }
        try apply("tool.started", #"{"id":"child","name":"read","status":"running","rootCallId":"root","parentCallId":"root","startedAt":1000,"detail":"{}","nativeSequence":3}"#, sequence: 1)
        try apply("tool.completed", #"{"id":"child","name":"read","status":"succeeded","finishedAt":1500,"detail":"result","resultMeta":{"path":"a","offset":1,"lines":[],"totalLines":0},"resultContent":[{"type":"text","text":"result"}],"nativeSequence":4}"#, sequence: 2)
        try apply("tool.started", #"{"id":"child","name":"read","status":"running","detail":"{}","startedAt":1000,"nativeSequence":3}"#, sequence: 3)
        try apply("tool.completed", #"{"id":"child","name":"read","status":"succeeded","detail":"result","nativeSequence":4}"#, sequence: 4)
        let tool = try XCTUnwrap(state.toolsBySession["s"]?.first)
        XCTAssertEqual(tool.status, "succeeded"); XCTAssertEqual(tool.arguments, "{}")
        XCTAssertEqual(tool.startedAt, 1000); XCTAssertEqual(tool.finishedAt, 1500)
        XCTAssertEqual(tool.parentCallId, "root"); XCTAssertEqual(tool.nativeSequence, 3)
        XCTAssertEqual(tool.sequence, 1); XCTAssertEqual(tool.resultContent?.count, 1)
        guard case .read = DSHToolResult.parse(tool) else { return XCTFail("Structured replay was lost") }
    }
    func testReplayedToolStartKeepsTerminalResultAndRestoresNativeStartPosition() throws {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        let complete = DSHEvent(envelope: DSHEnvelope(messageId: "done", deviceId: "device", machineId: "machine", sessionId: "s", sequence: 1,
            type: "tool.completed", payload: .object(["id": .string("t"), "name": .string("read"), "status": .string("succeeded"), "detail": .string("Result"), "nativeSequence": .number(10)])))
        reducer.reduce(complete, into: &state)
        let start = DSHEvent(envelope: DSHEnvelope(messageId: "start", deviceId: "device", machineId: "machine", sessionId: "s", sequence: 2,
            type: "tool.started", payload: .object(["id": .string("t"), "name": .string("read"), "status": .string("running"), "detail": .string("{}"), "nativeSequence": .number(8)])))
        reducer.reduce(start, into: &state)
        let tool = try XCTUnwrap(state.toolsBySession["s"]?.first)
        XCTAssertEqual(tool.status, "succeeded")
        XCTAssertEqual(tool.detail, "Result")
        XCTAssertEqual(tool.arguments, "{}")
        XCTAssertEqual(tool.nativeSequence, 8)
    }
    func testExecutionPagesMergeByNativeSequenceWithoutInventingTranscriptRows() throws {
        let reducer = DSHEventReducer()
        var state = DSHStoreState()
        func apply(_ type: String, _ json: String, seq: Int64) throws {
            reducer.reduce(event(type: type, messageID: "execution-\(seq)", sequence: seq,
                payload: try JSONDecoder().decode(DSHJSONValue.self, from: Data(json.utf8))), into: &state)
        }
        try apply("execution.page", #"{"sessionId":"s","hasMore":false,"beforeSeq":0,"records":[{"nativeSequence":0,"type":"turn/start","data":{"turn":1}},{"nativeSequence":4,"type":"llm/retry","data":{"retryId":"r","turn":1,"step":1,"retry":1}}]}"#, seq: 1)
        XCTAssertEqual(state.executionBySession?["s"]?.map(\.nativeSequence), [0, 4])
        XCTAssertTrue(DSHExecutionNotice.build(state.executionBySession?["s"] ?? []).allSatisfy { $0.sequence == nil })
        try apply("execution.recorded", #"{"sessionId":"s","record":{"nativeSequence":4,"type":"llm/retry","data":{"retryId":"r","turn":1,"step":1,"retry":1}}}"#, seq: 2)
        try apply("execution.page", #"{"sessionId":"s","hasMore":false,"records":[{"nativeSequence":4,"type":"llm/retry","data":{"retryId":"r","turn":999,"retry":99}}]}"#, seq: 3)
        let notice = try XCTUnwrap(DSHExecutionNotice.build(state.executionBySession?["s"] ?? []).first)
        XCTAssertEqual(notice.latestRetry?.turn, 1)
        XCTAssertEqual(notice.sequence, 2)
        XCTAssertEqual(state.executionBySession?["s"]?.count, 2)
    }

    @MainActor
    func testExecutionPageWaiterKeepsChildIdentityAndRejectsOtherRequestReplies() async throws {
        let restore = installCorrelationTestProfile(); defer { restore() }
        let transport = CorrelationTransport(), model = makeModel(transport: transport, isPaired: true)
        model.connect(); defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(80))
        let task = Task { try await model.executionPage(sessionID: "child", beforeSeq: 10, parentID: "parent", mode: "one-shot") }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(60))
        let captured = await transport.lastCommand(ofType: "execution.list")
        let command = try XCTUnwrap(captured)
        XCTAssertEqual(command.payload, .object(["beforeSeq": .number(10), "limit": .number(100), "parentSessionId": .string("parent"), "subagentMode": .string("one-shot")]))
        let payload: DSHJSONValue = .object(["sessionId": .string("child"), "hasMore": .bool(false), "beforeSeq": .number(0), "records": .array([
            .object(["nativeSequence": .number(0), "type": .string("turn/start"), "data": .object(["turn": .number(1)])])])])
        await transport.emit(event(type: "execution.page", messageID: "unrequested", sequence: 2, payload: payload))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(model.executionRecords(for: "child").isEmpty)
        await transport.emit(event(type: "execution.page", messageID: command.requestId, sequence: 3, payload: payload))
        let page = try await task.value
        XCTAssertEqual(page.beforeSeq, 0)
        XCTAssertEqual(model.executionRecords(for: "child").map(\.nativeSequence), [0])
        XCTAssertTrue(model.transcriptEntries(for: "child").isEmpty)
    }
    @MainActor
    func testFileDownloadKeepsScopeVersionAndOffsetsWithoutPersistingBytes() async throws {
        let restore = installCorrelationTestProfile(); defer { restore() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, isPaired: true)
        model.connect(); defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(80))
        var progress: [Int] = []
        let task = Task { try await model.downloadFile(.init(sessionID: "s", path: "图.txt", name: "../下载.txt")) { count, _ in progress.append(count) } }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(60))
        let firstCaptured = await transport.lastCommand(ofType: "workspace.bytes")
        let first = try XCTUnwrap(firstCaptured)
        XCTAssertEqual(first.sessionId, "s")
        XCTAssertEqual(first.payload, .object(["path": .string("图.txt"), "offset": .number(0), "length": .number(196608)]))
        // A response carrying the request id but another Session is ignored.
        func payload(_ scope: String, offset: Int, data: String, eof: Bool) -> DSHJSONValue {
            .object(["sessionId": .string(scope), "absolutePath": .string("/workspace/图.txt"), "version": .string("v1"),
                     "bytes": .number(6), "offset": .number(Double(offset)), "data": .string(data), "eof": .bool(eof)])
        }
        await transport.emit(event(type: "workspace.bytes", messageID: first.requestId, sequence: 2, payload: payload("wrong", offset: 0, data: "eHl6", eof: false)))
        await transport.emit(event(type: "workspace.bytes", messageID: first.requestId, sequence: 3, payload: payload("s", offset: 0, data: "YWJj", eof: false)))
        for _ in 0..<30 {
            if await transport.commandCount(ofType: "workspace.bytes") >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let secondCaptured = await transport.lastCommand(ofType: "workspace.bytes")
        let second = try XCTUnwrap(secondCaptured)
        XCTAssertNotEqual(first.requestId, second.requestId)
        XCTAssertEqual(second.payload, .object(["path": .string("图.txt"), "offset": .number(3), "length": .number(196608), "version": .string("v1")]))
        await transport.emit(event(type: "workspace.bytes", messageID: second.requestId, sequence: 4, payload: payload("s", offset: 3, data: "ZGVm", eof: true)))
        let url = try await task.value
        XCTAssertEqual(url.lastPathComponent, "下载.txt")
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent.hasPrefix("DSH-file-"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "abcdef")
        XCTAssertEqual(progress, [3, 6])
        XCTAssertFalse(model.state.unknownEvents.contains { $0.type == "workspace.bytes" })
    }

    @MainActor
    func testFileFailureStaysInlineAndDoesNotSendPromptOrExposePartialFile() async throws {
        let restore = installCorrelationTestProfile(); defer { restore() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, isPaired: true)
        model.connect(); defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(80))
        let task = Task { try await model.downloadFile(.init(sessionID: "s", path: "a.pdf")) }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(60))
        let captured = await transport.lastCommand(ofType: "workspace.bytes")
        let command = try XCTUnwrap(captured)
        await transport.emit(event(type: "protocol.error", messageID: command.requestId, sequence: 2,
            payload: .object(["code": .string("bridge-request-failed"), "message": .string("File changed"), "retryable": .bool(false)])))
        do { _ = try await task.value; XCTFail("Changed file must fail") }
        catch { XCTAssertEqual(error.localizedDescription, "File changed") }
        XCTAssertNil(model.errorMessage, "The file view owns its error; do not show a second global alert")
        let sends = await transport.commandCount(ofType: "prompt.send")
        XCTAssertEqual(sends, 0)
        XCTAssertFalse(model.state.protocolErrorsByRequestID.keys.contains(command.requestId))
    }

    @MainActor
    func testFileDownloadRejectsOversizeBeforeSharing() async throws {
        let restore = installCorrelationTestProfile(); defer { restore() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, isPaired: true)
        model.connect(); defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(80))
        let task = Task { try await model.downloadFile(.init(sessionID: "s", path: "big.bin")) }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(60))
        let captured = await transport.lastCommand(ofType: "workspace.bytes")
        let command = try XCTUnwrap(captured)
        await transport.emit(event(type: "workspace.bytes", messageID: command.requestId, sequence: 2, payload: .object([
            "sessionId": .string("s"), "absolutePath": .string("/big.bin"), "version": .string("v"), "offset": .number(0),
            "data": .string("YQ=="), "bytes": .number(100 * 1_024 * 1_024), "eof": .bool(false)])))
        do { _ = try await task.value; XCTFail("Oversized file must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("64 MB")) }
        let count = await transport.commandCount(ofType: "workspace.bytes")
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testCancellingFileReadStopsFurtherChunksAndRemovesTemporaryFile() async throws {
        let restore = installCorrelationTestProfile(); defer { restore() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, isPaired: true)
        model.connect(); defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(80))
        func downloads() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("DSH-file-") })
        }
        let before = downloads()
        let task = Task { try await model.downloadFile(.init(sessionID: "s", path: "a.bin")) }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled download must not return a file") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(downloads(), before)
        let count = await transport.commandCount(ofType: "workspace.bytes")
        XCTAssertEqual(count, 1)
    }

    func testWorkflowCatalogDoesNotPolluteTimelineAndOldReplayCannotRegressMembers() throws {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        func apply(_ json: String, seq: Int64) throws {
            let payload = try JSONDecoder().decode(DSHJSONValue.self, from: Data(json.utf8))
            reducer.reduce(event(type: "workflow.changed", messageID: "workflow-\(seq)", sequence: seq, payload: payload), into: &state)
        }
        try apply(#"{"sessionId":"s","inTranscript":false,"run":{"id":"r","name":"Review","status":"completed","nativeSequence":10,"updatedNativeSequence":20,"members":[{"seq":1,"label":"Read","childId":"child","status":"completed"}]}}"#, seq: 2)
        XCTAssertNil(state.workflowsBySession?["s"]?.first?.sequence)
        try apply(#"{"sessionId":"s","run":{"id":"r","name":"Review","status":"running","nativeSequence":10,"updatedNativeSequence":11,"members":[{"seq":1,"label":"Read","childId":"child","status":"running"}]}}"#, seq: 4)
        let run = try XCTUnwrap(state.workflowsBySession?["s"]?.first)
        XCTAssertEqual(run.status, "completed")
        XCTAssertEqual(run.members.first?.status, "completed")
        XCTAssertEqual(run.sequence, 4)
        let messages = [DSHChatMessage(id: "user", role: .user, markdown: "Task", sequence: 1),
                        DSHChatMessage(id: "answer", role: .assistant, markdown: "Done", sequence: 5)]
        XCTAssertEqual(messages.transcriptEntries(with: [], workflows: [run]).map(\.id), ["turn-user", "workflow-r", "turn-answer"])
    }

    @MainActor
    func testWorkflowPayloadInvalidatesTranscriptCacheAndKeepsOneRowAcrossUpdates() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, isPaired: true)
        XCTAssertTrue(model.transcriptEntries(for: "s").isEmpty)
        model.connect()
        defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(50))
        let started = try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"sessionId":"s","run":{"id":"r","name":"Review","status":"running","nativeSequence":1,"updatedNativeSequence":1,"members":[]}}"#.utf8))
        await transport.emit(event(type: "workflow.changed", messageID: "start", sequence: 1, payload: started))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.transcriptEntries(for: "s").map(\.id), ["workflow-r"])
        let finished = try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"sessionId":"s","run":{"id":"r","name":"Review","status":"cancelled","nativeSequence":1,"updatedNativeSequence":2,"members":[]}}"#.utf8))
        await transport.emit(event(type: "workflow.changed", messageID: "end", sequence: 2, payload: finished))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.transcriptEntries(for: "s").count, 1)
        guard case .workflow(let run) = model.transcriptEntries(for: "s").first else { return XCTFail("Missing workflow row") }
        XCTAssertEqual(run.status, "cancelled")
    }

    @MainActor
    func testWorkflowNavigationUsesVerifiedParentCatalogAndAllowsCachedOfflineReading() async throws {
        let catalog = try JSONDecoder().decode(DSHSubagentCatalog.self, from: Data(#"{"parentSessionId":"parent","parentAvailable":false,"entries":[{"kind":"child","id":"child","mode":"one-shot","activity":"inactive","hasChildren":false}]}"#.utf8))
        var state = DSHStoreState()
        state.subagentCatalogs = ["parent": catalog]
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: state, isPaired: false)
        let child = try await model.workflowChild("child", parentID: "parent")
        XCTAssertEqual(child.mode, "one-shot")
        model.openSubagent(child, parentID: "parent")
        do { _ = try await model.workflowChild("child", parentID: "wrong-parent"); XCTFail("Cannot guess a child address") } catch { }
        let opens = await transport.commandCount(ofType: "session.open")
        XCTAssertEqual(opens, 0, "Offline cached reading must not attempt a failing network operation")
        model.disconnect()
    }
    @MainActor
    func testGoalSnapshotReplyCannotOverwriteLaterLiveRevisionInSameBatch() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, isPaired: true)
        model.connect()
        defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(50))
        model.requestGoalState(for: "s")
        try await Task.sleep(for: .milliseconds(50))
        let captured = await transport.lastCommand(ofType: "goal.get")
        let command = try XCTUnwrap(captured)
        let live = try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"sessionId":"s","goal":{"id":"g","revision":3,"objective":"Live","phase":"active","maxGoalRounds":12},"roundsStarted":4}"#.utf8))
        let old = try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"sessionId":"s","goal":{"id":"g","revision":2,"objective":"Old","phase":"paused","maxGoalRounds":12},"roundsStarted":3,"activation":"disarmed"}"#.utf8))
        await transport.emit(event(type: "goal.changed", messageID: "new", sequence: 1, payload: live))
        await transport.emit(event(type: "goal.state", messageID: command.requestId, sequence: 2, payload: old))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.goalState(for: "s")?.goal?.objective, "Live")
        XCTAssertEqual(model.goalState(for: "s")?.goal?.revision, 3)
    }

    func testNativeGoalConflictDoesNotMarkBridgeUnreachable() {
        var state = DSHStoreState()
        state.bridgeReachable = true
        let reducer = DSHEventReducer()
        reducer.reduce(event(type: "protocol.error", messageID: "conflict", sequence: 1,
            payload: .object(["code": .string("bridge-request-failed"), "message": .string("Goal revision changed"),
                "retryable": .bool(false)])), into: &state)
        XCTAssertEqual(state.bridgeReachable, true)
    }
    @MainActor
    func testGoalControlsKeepExpectedRevisionAndRejectStaleLocalEdits() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, isPaired: true)
        _ = await model.preparePromptPersistence(expectedMachineGeneration: model.currentMachineGeneration, expectedMachineID: model.machineID)
        model.connect()
        defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(50))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        let original = try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"sessionId":"s","goal":{"id":"g","revision":2,"objective":"Ship","phase":"active","maxGoalRounds":12},"roundsStarted":3}"#.utf8))
        await transport.emit(event(type: "goal.changed", messageID: "goal-2", sequence: 2, payload: original))
        try await Task.sleep(for: .milliseconds(80))
        let goal = try XCTUnwrap(model.goalState(for: "s")?.goal)
        let pause = Task { @MainActor in try await model.updateGoal(goal, in: "s", action: "pause") }
        defer { pause.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        let captured = await transport.lastCommand(ofType: "goal.update")
        let command = try XCTUnwrap(captured)
        XCTAssertEqual(command.payload, .object(["action": .string("pause"), "ref": .object(["id": .string("g"), "revision": .number(2)])]))
        let paused = try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"sessionId":"s","goal":{"id":"g","revision":3,"objective":"Ship","phase":"paused","maxGoalRounds":12},"roundsStarted":3,"activation":"disarmed"}"#.utf8))
        await transport.emit(event(type: "goal.changed", messageID: "goal-3", sequence: 3, payload: paused))
        await transport.emit(event(type: "goal.updated", messageID: command.requestId, sequence: 4,
            payload: .object(["sessionId": .string("s"), "requestId": .string(command.requestId), "action": .string("pause"),
                "ref": .object(["id": .string("g"), "revision": .number(3)])])))
        try await pause.value
        XCTAssertEqual(model.goalState(for: "s")?.goal?.revision, 3)
        do { try await model.updateGoal(goal, in: "s", action: "edit", objective: "Old edit"); XCTFail("Old revision must not be sent") } catch { }
        let count = await transport.commandCount(ofType: "goal.update")
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testGoalMutationUnknownOutcomeRetainsRequestIdentity() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        var state = DSHStoreState()
        let original = try JSONDecoder().decode(DSHGoalState.self, from: Data(#"{"sessionId":"s","goal":{"id":"g","revision":2,"objective":"Ship","phase":"active","maxGoalRounds":12},"roundsStarted":3}"#.utf8))
        state.goalBySession = ["s": original]
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: state, isPaired: true)
        _ = await model.preparePromptPersistence(expectedMachineGeneration: model.currentMachineGeneration, expectedMachineID: model.machineID)
        model.connect()
        defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(50))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(60))
        let goal = try XCTUnwrap(original.goal)
        let first = Task { @MainActor in try await model.updateGoal(goal, in: "s", action: "pause") }
        defer { first.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        let captured = await transport.lastCommand(ofType: "goal.update")
        let command = try XCTUnwrap(captured)
        await transport.emit(event(type: "protocol.error", messageID: command.requestId, sequence: 2,
            payload: .object(["code": .string("bridge-result-unknown"), "message": .string("Unknown result"), "retryable": .bool(false)])))
        do { try await first.value; XCTFail("Unknown outcome must be reported") } catch { }
        let retry = Task { @MainActor in try await model.updateGoal(goal, in: "s", action: "pause") }
        defer { retry.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        let retried = await transport.lastCommand(ofType: "goal.update")
        XCTAssertEqual(retried?.requestId, command.requestId)
        await transport.emit(event(type: "goal.updated", messageID: command.requestId, sequence: 3,
            payload: .object(["sessionId": .string("s"), "requestId": .string(command.requestId), "action": .string("pause"),
                "ref": .object(["id": .string("g"), "revision": .number(3)])])))
        try await retry.value
    }

    @MainActor
    func testNativeGoalCreationKeepsUnknownRequestAndUsesCreateReceipt() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let live = makeModel(transport: transport, isPaired: true)
        _ = await live.preparePromptPersistence(expectedMachineGeneration: live.currentMachineGeneration, expectedMachineID: live.machineID)
        live.connect(); defer { live.disconnect() }
        try await Task.sleep(for: .milliseconds(50))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(60))
        let create = Task { @MainActor in try await live.createGoal(in: "s", objective: "Read all Native information", maxGoalRounds: 7) }
        defer { create.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        let captured = await transport.lastCommand(ofType: "goal.update"), command = try XCTUnwrap(captured)
        XCTAssertEqual(command.payload, .object(["action": .string("create"), "objective": .string("Read all Native information"), "maxGoalRounds": .number(7)]))
        await transport.emit(event(type: "protocol.error", messageID: command.requestId, sequence: 2,
            payload: .object(["code": .string("bridge-result-unknown"), "message": .string("Unknown create"), "retryable": .bool(false)])))
        do { try await create.value; XCTFail("Unknown creation must retain its original identity") } catch { }
        let retry = Task { @MainActor in try await live.createGoal(in: "s", objective: "Read all Native information", maxGoalRounds: 7) }
        defer { retry.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        let repeated = await transport.lastCommand(ofType: "goal.update")
        XCTAssertEqual(repeated?.requestId, command.requestId)
        await transport.emit(event(type: "goal.updated", messageID: command.requestId, sequence: 3,
            payload: .object(["sessionId": .string("s"), "requestId": .string(command.requestId), "action": .string("create"), "ref": .object(["id": .string("native"), "revision": .number(1)])])))
        try await retry.value
    }

    func testLiveGoalStateSurvivesHistoricalReplayAndClearedGoalCannotReappear() throws {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        func apply(_ type: String, _ json: String, _ seq: Int64, historical: Bool = false) throws {
            let payload = try JSONDecoder().decode(DSHJSONValue.self, from: Data(json.utf8))
            reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: "g-\(seq)", deviceId: "d", machineId: "m",
                historyBatchId: historical ? "batch" : nil, sequence: seq, type: type, payload: payload)), into: &state)
        }
        try apply("goal.state", #"{"sessionId":"s","goal":{"id":"g","revision":3,"objective":"Ship","phase":"active","maxGoalRounds":12},"roundsStarted":4,"activation":"armed"}"#, 1)
        try apply("history.started", #"{"sessionId":"s","batchId":"batch"}"#, 2)
        try apply("goal.changed", #"{"sessionId":"s","goal":{"id":"g","revision":2,"objective":"Old","phase":"paused","maxGoalRounds":12},"roundsStarted":3}"#, 3, historical: true)
        XCTAssertEqual(state.goalBySession?["s"]?.goal?.revision, 3)
        XCTAssertEqual(state.goalBySession?["s"]?.activation, "armed")
        try apply("goal.changed", #"{"sessionId":"s","goal":null,"roundsStarted":0}"#, 4)
        try apply("goal.changed", #"{"sessionId":"s","goal":{"id":"g","revision":3,"objective":"Ship","phase":"active","maxGoalRounds":12},"roundsStarted":4}"#, 5, historical: true)
        XCTAssertNil(state.goalBySession?["s"]?.goal)
        XCTAssertEqual(state.goalBySession?["s"]?.roundsStarted, 0)
    }

    @MainActor
    func testPlanProjectionWinsOverHistoryAndIgnoresOldGeneration() throws {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        func apply(_ json: String, _ seq: Int64) throws {
            let payload = try JSONDecoder().decode(DSHJSONValue.self, from: Data(json.utf8))
            reducer.reduce(event(type: "plan.projection", messageID: "p-\(seq)", sequence: seq, payload: payload), into: &state)
        }
        try apply(#"{"sessionId":"s","epoch":"one","seq":10,"active":true,"pending":true,"available":true,"supported":true}"#, 1)
        try apply(#"{"sessionId":"s","epoch":"one","seq":9,"active":false,"pending":false,"available":true,"supported":true}"#, 2)
        XCTAssertEqual(state.planProjections?["s"]?.pending, true)
        try apply(#"{"sessionId":"s","epoch":"two","seq":5,"active":false,"pending":true,"available":true,"supported":true}"#, 3)
        try apply(#"{"sessionId":"s","epoch":"one","seq":20,"active":true,"pending":false,"available":true,"supported":true}"#, 4)
        XCTAssertEqual(state.planProjections?["s"]?.epoch, "two")
        state.planBySession = ["s": DSHPlanState(sessionId: "s", active: true)]
        let model = makeModel(transport: DSHPreviewTransport(), initialState: state)
        XCTAssertEqual(model.planState(for: "s")?.active, false)
        XCTAssertEqual(model.planState(for: "s")?.pending, true)
    }
    func testDecisionSnapshotCannotResurrectResolvedQuestionsOrRetiredBridgeEpoch() throws {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        func apply(_ type: String, _ json: String, _ sequence: Int64) throws {
            let payload = try JSONDecoder().decode(DSHJSONValue.self, from: Data(json.utf8))
            reducer.reduce(event(type: type, messageID: "decision-\(sequence)", sequence: sequence, payload: payload), into: &state)
        }
        try apply("decisions.snapshot", #"{"stateVersion":{"epoch":"host-1","revision":1},"approvals":[],"questions":[{"id":"q","sessionId":"s","questions":[{"id":"item","question":"Continue?"}]}]}"#, 1)
        XCTAssertEqual(state.pendingQuestions.count, 1)
        try apply("question.resolved", #"{"id":"q","sessionId":"s","stateVersion":{"epoch":"host-1","revision":2}}"#, 2)
        try apply("decisions.snapshot", #"{"stateVersion":{"epoch":"host-1","revision":1},"approvals":[],"questions":[{"id":"q","sessionId":"s","questions":[{"id":"item","question":"Continue?"}]}]}"#, 3)
        XCTAssertTrue(state.pendingQuestions.isEmpty)
        try apply("decisions.snapshot", #"{"stateVersion":{"epoch":"host-2","revision":0},"approvals":[],"questions":[]}"#, 4)
        try apply("question.asked", #"{"id":"q","sessionId":"s","questions":[{"id":"item","question":"Continue?"}],"stateVersion":{"epoch":"host-1","revision":3}}"#, 5)
        XCTAssertTrue(state.pendingQuestions.isEmpty)
        XCTAssertEqual(state.decisionVersion?.epoch, "host-2")
    }

    @MainActor
    func testQuestionAnswerFailurePreservesDraftAndCanRetryUntilResolution() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let request = DSHQuestionRequest(id: "draft-\(UUID().uuidString)", sessionId: "s", questions: [DSHQuestion(id: "item", question: "Continue?")])
        var state = DSHStoreState()
        state.pendingQuestions = [request]
        let transport = CorrelationTransport(failFirstTypes: ["question.answer"])
        let model = makeModel(transport: transport, initialState: state, isPaired: true)
        model.connect()
        defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(50))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(60))
        let draft = DSHQuestionDraft(questions: request.questions, selections: [:], custom: ["item": "Keep going"], skipped: [])
        model.saveQuestionDraft(draft, for: request)
        let answers = [DSHQuestionAnswer(id: "item", selected: [], custom: "Keep going")]
        do { try await model.answer(request, answers: answers); XCTFail("First send must fail") } catch { }
        XCTAssertEqual(model.questionDraft(for: request), draft)
        XCTAssertEqual(model.pendingQuestions.count, 1)
        let retry = Task { @MainActor in try await model.answer(request, answers: answers) }
        defer { retry.cancel() }
        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "question.resolved", messageID: "resolved", sequence: 2,
            payload: .object(["id": .string(request.id), "sessionId": .string("s")])))
        try await retry.value
        XCTAssertNil(model.questionDraft(for: request))
    }

    @MainActor
    func testApprovalFailureKeepsPendingDecisionAndExpiredApprovalCannotSend() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let request = DSHApprovalRequest(id: "approval", sessionId: "s", toolName: "shell", reason: "Run?")
        let expired = DSHApprovalRequest(id: "expired", sessionId: "s", toolName: "shell", reason: "Run?", expiresAt: 1)
        var state = DSHStoreState()
        state.pendingApprovals = [request, expired]
        let transport = CorrelationTransport(failingTypes: ["approval.decide"])
        let model = makeModel(transport: transport, initialState: state, isPaired: true)
        model.connect()
        defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(50))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(60))
        do { try await model.decide(request, allow: true); XCTFail("Transport must fail") } catch { }
        XCTAssertEqual(model.pendingApprovals.count, 2)
        XCTAssertEqual(model.approvalDecisionDraft(for: request), true)
        let before = await transport.commandCount(ofType: "approval.decide")
        do { try await model.decide(expired, allow: false); XCTFail("Expired decision must not send") } catch { }
        let after = await transport.commandCount(ofType: "approval.decide")
        XCTAssertEqual(after, before)
        await transport.emit(event(type: "approval.resolved", messageID: "resolved", sequence: 2,
            payload: .object(["id": .string(request.id), "allowed": .bool(false)])))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(model.approvalDecisionDraft(for: request))
    }
    @MainActor
    func testContinuableSubagentUsesParentAddressAndStableRetryIdentity() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: .init(), isPaired: true)
        _ = await model.preparePromptPersistence(expectedMachineGeneration: model.currentMachineGeneration,
                                                  expectedMachineID: model.machineID)
        model.connect()
        defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(50))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        let catalog = try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"parentSessionId":"parent","parentAvailable":true,"entries":[{"kind":"child","id":"child","mode":"continuable","activity":"running","hasChildren":false,"label":"Task"}]}"#.utf8))
        await transport.emit(event(type: "subagent.catalog", messageID: "catalog", sequence: 2, payload: catalog))
        try await Task.sleep(for: .milliseconds(100))
        let first = Task { @MainActor in try await model.controlSubagent(childID: "child", parentID: "parent", text: "continue", delivery: "steer") }
        defer { first.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        let captured = await transport.lastCommand(ofType: "subagent.prompt")
        let command = try XCTUnwrap(captured)
        XCTAssertEqual(command.sessionId, "child")
        guard case .object(let payload) = command.payload else { return XCTFail("Missing child address") }
        XCTAssertEqual(payload["parentSessionId"], .string("parent"))
        XCTAssertEqual(payload["mode"], .string("continuable"))
        XCTAssertEqual(payload["delivery"], .string("steer"))
        await transport.emit(event(type: "protocol.error", messageID: command.requestId, sequence: 3,
            payload: .object(["code": .string("bridge-result-unknown"), "message": .string("Unknown"), "retryable": .bool(false)])))
        do { try await first.value; XCTFail("Uncertain result must keep request identity") } catch { }
        let retry = Task { @MainActor in try await model.controlSubagent(childID: "child", parentID: "parent", text: "continue", delivery: "steer") }
        defer { retry.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        let retried = await transport.lastCommand(ofType: "subagent.prompt")
        XCTAssertEqual(retried?.requestId, command.requestId)
        await transport.emit(event(type: "subagent.receipt", messageID: command.requestId, sequence: 4,
            payload: .object(["parentSessionId": .string("parent"), "childSessionId": .string("child"),
                "requestId": .string(command.requestId), "action": .string("prompt"), "messageId": .string("inbox")])))
        try await retry.value
        let ordinary = await transport.commandCount(ofType: "prompt.send")
        XCTAssertEqual(ordinary, 0)
    }

    @MainActor
    func testSubagentInvalidationRejectsOldCatalogReplyInSameBatch() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: .init(), isPaired: true)
        model.connect()
        defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(50))
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        try await Task.sleep(for: .milliseconds(80))
        let token = UUID()
        model.watchSubagents(for: "parent", token: token)
        defer { model.unwatchSubagents(for: "parent", token: token) }
        try await Task.sleep(for: .milliseconds(60))
        let captured = await transport.lastCommand(ofType: "subagent.catalog")
        let old = try XCTUnwrap(captured)
        await transport.emit(event(type: "subagent.catalog.invalidated", messageID: "invalidate", sequence: 2,
            payload: .object(["parentSessionId": .string("parent")])))
        await transport.emit(event(type: "subagent.catalog", messageID: old.requestId, sequence: 3,
            payload: .object(["parentSessionId": .string("parent"), "parentAvailable": .bool(true), "entries": .array([])])))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.subagentCatalog(for: "parent"))
        let refreshed = await transport.lastCommand(ofType: "subagent.catalog")
        XCTAssertNotEqual(refreshed?.requestId, old.requestId)
    }
    @MainActor
    func testAuthoritativeQueueRetiresLocalEchoAndMutatesExactOccurrence() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: .init(), isPaired: true)
        _ = await model.preparePromptPersistence(expectedMachineGeneration: model.currentMachineGeneration,
                                                  expectedMachineID: model.machineID)
        model.connect()
        defer { model.disconnect() }
        try await Task.sleep(for: .milliseconds(50))
        model.noteQueuedPrompt(text: "Task", mode: "queue", requestId: "rpc", for: "s")
        await transport.emit(event(type: "connection.ready", messageID: "ready", sequence: 1, payload: .object([:])))
        let payload = try JSONDecoder().decode(DSHJSONValue.self, from: Data(#"{"sessionId":"s","available":true,"items":[{"id":"item","placement":"queued","rpcId":"rpc","message":{"id":"item","content":[{"type":"text","text":"Task"}]}}]}"#.utf8))
        await transport.emit(event(type: "queue.changed", messageID: "queue", sequence: 2, payload: payload))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.queuedPrompts(for: "s").isEmpty)
        let item = try XCTUnwrap(model.serverQueue(for: "s")?.items.first)
        let remove = Task { @MainActor in try await model.updateServerQueue(item, in: "s", action: "remove") }
        defer { remove.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        let captured = await transport.lastCommand(ofType: "queue.update")
        let command = try XCTUnwrap(captured)
        XCTAssertEqual(command.payload, .object(["itemId": .string("item"), "action": .string("remove")]))
        await transport.emit(event(type: "queue.updated", messageID: command.requestId, sequence: 3,
            payload: .object(["sessionId": .string("s"), "itemId": .string("item"), "requestId": .string(command.requestId)])))
        await transport.emit(event(type: "queue.changed", messageID: "empty", sequence: 4,
            payload: .object(["sessionId": .string("s"), "available": .bool(true), "items": .array([])])))
        try await remove.value
        XCTAssertEqual(model.serverQueue(for: "s")?.items.count, 0)
    }
    func testBackgroundJobListsReplaceAndClearWithinTheirOwnSession() throws {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        func apply(_ json: String, _ seq: Int64) throws {
            let payload = try JSONDecoder().decode(DSHJSONValue.self, from: Data(json.utf8))
            reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: "jobs-\(seq)", deviceId: "phone",
                machineId: "mac", sequence: seq, type: "jobs.changed", payload: payload)), into: &state)
        }
        try apply(#"{"sessionId":"s","available":true,"jobs":[{"id":"j","kind":"shell","label":"Build","status":"running","startedAt":100}]}"#, 1)
        XCTAssertEqual(state.jobsBySession?["s"]?.jobs.first?.status, "running")
        XCTAssertNil(state.jobsBySession?["other"])
        reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: "offline", deviceId: "phone", machineId: "mac",
            sequence: 0, type: "transport.state", payload: .object(["state": .string("disconnected")]))), into: &state)
        XCTAssertEqual(state.jobsBySession?["s"]?.available, false)
        try apply(#"{"sessionId":"s","available":false,"jobs":[{"id":"j","kind":"shell","label":"Build","status":"running","startedAt":100}]}"#, 2)
        XCTAssertEqual(state.jobsBySession?["s"]?.available, false)
        try apply(#"{"sessionId":"s","available":true,"jobs":[]}"#, 3)
        XCTAssertEqual(state.jobsBySession?["s"]?.jobs.count, 0)
    }
    @MainActor
    func testQuestionCancellationWaitsForResolutionAndDoesNotSubmitAnAnswer() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let request = DSHQuestionRequest(id: "q", sessionId: "s", questions: [DSHQuestion(id: "item", question: "Approve?")])
        var state = DSHStoreState()
        state.pendingQuestions = [request]
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: state, isPaired: true)
        _ = await model.preparePromptPersistence(expectedMachineGeneration: model.currentMachineGeneration,
                                                  expectedMachineID: model.machineID)
        model.connect()
        try await Task.sleep(for: .milliseconds(50))
        let cancel = Task { @MainActor in try await model.cancelQuestion(request) }
        defer { cancel.cancel(); model.disconnect() }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(model.pendingQuestions.count, 1)
        let command = await transport.lastCommand(ofType: "question.cancel")
        XCTAssertEqual(command?.payload, .object(["questionId": .string("q")]))
        await transport.emit(event(type: "question.resolved", messageID: "resolved", sequence: 1,
            payload: .object(["id": .string("q"), "sessionId": .string("s")])))
        try await cancel.value
        XCTAssertTrue(model.pendingQuestions.isEmpty)
        let answers = await transport.commandCount(ofType: "question.answer")
        XCTAssertEqual(answers, 0)
    }

    @MainActor
    func testQuestionCancellationFailureKeepsQuestionAvailableForRetry() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let request = DSHQuestionRequest(id: "q", sessionId: "s", questions: [DSHQuestion(id: "item", question: "Approve?")])
        var state = DSHStoreState()
        state.pendingQuestions = [request]
        let model = makeModel(transport: CorrelationTransport(failingTypes: ["question.cancel"]), initialState: state, isPaired: true)
        do { try await model.cancelQuestion(request); XCTFail("Cancellation should fail while disconnected") }
        catch { XCTAssertEqual(model.pendingQuestions, [request]) }
        model.disconnect()
    }
    @MainActor
    func testStagedCommandUploadsReceiptAndNeverSendsOrdinaryPrompt() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: .init(), isPaired: true,
                                transactionDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        _ = await model.preparePromptPersistence(expectedMachineGeneration: model.currentMachineGeneration,
                                                  expectedMachineID: model.machineID)
        model.connect()
        try await Task.sleep(for: .milliseconds(50))
        let requestID = "command-\(UUID().uuidString)"
        let attachment = DSHStagedAttachment(name: "spec.txt", data: Data("spec".utf8), isImage: false)
        let task = Task { @MainActor in
            try await model.sendStagedPromptPersisted("/plan use this", attachments: [attachment], to: "s",
                                                       mode: "command", requestId: requestID)
        }
        defer { task.cancel(); model.disconnect() }
        try await Task.sleep(for: .milliseconds(100))
        let upload = await transport.lastCommand(ofType: "attachment.upload")
        let uploadID = try XCTUnwrap(upload?.requestId)
        await transport.emit(event(type: "attachment.uploaded", messageID: uploadID, sequence: 1,
            payload: .object(["sessionId": .string("s"), "requestId": .string(uploadID),
                              "receiptId": .string("receipt-command"), "name": .string("spec.txt")])))
        try await Task.sleep(for: .milliseconds(150))
        let capturedCommand = await transport.lastCommand(ofType: "command.execute")
        let command = try XCTUnwrap(capturedCommand)
        XCTAssertEqual(command.requestId, requestID)
        XCTAssertEqual(command.payload, .object(["line": .string("/plan use this"),
            "attachments": .array([.object(["type": .string("file"), "receiptId": .string("receipt-command")])])]))
        await transport.emit(event(type: "protocol.error", messageID: requestID, sequence: 2,
            payload: .object(["code": .string("bridge-result-unknown"), "message": .string("Unknown result"), "retryable": .bool(false)])))
        do { _ = try await task.value; XCTFail("The unknown result must preserve the draft for retry") } catch { }
        XCTAssertEqual(model.stagedPromptRequestID(text: "/plan use this", attachments: [attachment], sessionID: "s"), requestID)
        let retry = Task { @MainActor in
            try await model.sendStagedPromptPersisted("/plan use this", attachments: [attachment], to: "s",
                                                       mode: "command", requestId: requestID)
        }
        defer { retry.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        let uploads = await transport.commandCount(ofType: "attachment.upload")
        XCTAssertEqual(uploads, 1, "A completed upload must not run again after an uncertain command result")
        let executions = await transport.commandCount(ofType: "command.execute")
        XCTAssertEqual(executions, 2)
        let retried = await transport.lastCommand(ofType: "command.execute")
        XCTAssertEqual(retried?.requestId, requestID)
        XCTAssertEqual(retried?.payload, command.payload)
        await transport.emit(event(type: "command.result", messageID: requestID, sequence: 3,
            payload: .object(["sessionId": .string("s"), "requestId": .string(requestID), "matched": .bool(true),
                              "kind": .string("success")])))
        let sent = try await retry.value
        XCTAssertTrue(sent)
        XCTAssertEqual(model.pendingSendCount(for: "s"), 0)
        let prompts = await transport.commandCount(ofType: "prompt.send")
        XCTAssertEqual(prompts, 0)
        model.disconnect()
    }
    @MainActor
    func testCommandInvalidationRejectsInflightOldCatalogAndRefreshesVisibleSession() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: .init(), isPaired: true)
        _ = await model.preparePromptPersistence(expectedMachineGeneration: model.currentMachineGeneration,
                                                  expectedMachineID: model.machineID)
        model.connect()
        model.setConversationVisible("s", visible: true)
        model.requestCommands(for: "s")
        try await Task.sleep(for: .milliseconds(60))
        let old = await transport.lastCommand(ofType: "command.catalog")
        let oldID = try XCTUnwrap(old?.requestId)
        await transport.emit(event(type: "command.catalog.invalidated", messageID: "invalidate", sequence: 1, payload: .object([:])))
        await transport.emit(event(type: "command.catalog", messageID: oldID, sequence: 2,
            payload: .object(["sessionId": .string("s"), "commands": .array([.object(["name": .string("old"), "description": .string("Old")])])])))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.commandCatalog(for: "s"))
        let fresh = await transport.lastCommand(ofType: "command.catalog")
        let freshID = try XCTUnwrap(fresh?.requestId)
        XCTAssertNotEqual(oldID, freshID)
        await transport.emit(event(type: "command.catalog", messageID: freshID, sequence: 3,
            payload: .object(["sessionId": .string("s"), "commands": .array([])])))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.commandCatalog(for: "s")?.commands.count, 0)
        model.disconnect()
    }
    func testTodoSnapshotsReplaceListsAndExplicitEmptyClearsProgress() throws {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        func apply(_ json: String, _ seq: Int64) throws {
            let payload = try JSONDecoder().decode(DSHJSONValue.self, from: Data(json.utf8))
            reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: "todo-\(seq)", deviceId: "phone",
                machineId: "mac", sequence: seq, type: "todo.changed", payload: payload)), into: &state)
        }
        try apply(#"{"sessionId":"s","todos":[{"content":"Read","status":"in_progress"}]}"#, 1)
        XCTAssertEqual(state.todoBySession?["s"]?.todos.first?.status, "in_progress")
        try apply(#"{"sessionId":"s","todos":[{"content":"Verify","status":"completed"}]}"#, 2)
        XCTAssertEqual(state.todoBySession?["s"]?.todos.count, 1)
        XCTAssertEqual(state.todoBySession?["s"]?.todos.first?.content, "Verify")
        XCTAssertNil(state.todoBySession?["other"])
        try apply(#"{"sessionId":"s","todos":[]}"#, 3)
        XCTAssertEqual(state.todoBySession?["s"]?.todos, [])
    }
    func testCollaborationStateIsSessionScopedAndClearRemovesGoal() throws {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        func apply(_ type: String, _ json: String, _ seq: Int64) throws {
            let payload = try JSONDecoder().decode(DSHJSONValue.self, from: Data(json.utf8))
            reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: "e\(seq)", deviceId: "phone",
                machineId: "mac", sequence: seq, type: type, payload: payload)), into: &state)
        }
        try apply("plan.changed", #"{"sessionId":"s","active":true}"#, 1)
        XCTAssertEqual(state.planBySession?["s"]?.active, true)
        XCTAssertNil(state.planBySession?["other"])
        try apply("goal.changed", #"{"sessionId":"s","goal":{"id":"g","revision":2,"objective":"Ship","phase":"paused","maxGoalRounds":12},"roundsStarted":3}"#, 2)
        XCTAssertEqual(state.goalBySession?["s"]?.goal?.phase, "paused")
        XCTAssertEqual(state.goalBySession?["s"]?.roundsStarted, 3)
        try apply("goal.activation", #"{"sessionId":"s","id":"g","revision":1,"activation":"armed"}"#, 3)
        XCTAssertNil(state.goalBySession?["s"]?.activation, "A stale goal revision cannot arm the current goal")
        try apply("goal.activation", #"{"sessionId":"s","id":"g","revision":2,"activation":"disarmed"}"#, 4)
        XCTAssertEqual(state.goalBySession?["s"]?.activation, "disarmed")
        try apply("goal.round", #"{"sessionId":"s","id":"other","round":10}"#, 5)
        XCTAssertEqual(state.goalBySession?["s"]?.roundsStarted, 3)
        try apply("goal.round", #"{"sessionId":"s","id":"g","round":4}"#, 6)
        XCTAssertEqual(state.goalBySession?["s"]?.roundsStarted, 4)
        try apply("goal.round", #"{"sessionId":"s","id":"g","round":2}"#, 7)
        XCTAssertEqual(state.goalBySession?["s"]?.roundsStarted, 4)
        try apply("goal.changed", #"{"sessionId":"s","goal":null,"roundsStarted":0}"#, 8)
        XCTAssertNil(state.goalBySession?["s"]?.goal)
    }
    func testStartupWaitsForPresenceAndBridgeInsteadOfReportingUnreachable() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        func control(_ type: String, _ payload: DSHJSONValue) {
            reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: UUID().uuidString,
                deviceId: "phone", machineId: "mac", sequence: 0,
                type: type, payload: payload)), into: &state)
        }
        XCTAssertTrue(state.isAwaitingInitialSessions)
        control("transport.state", .object(["state": .string("connecting")]))
        XCTAssertTrue(state.isAwaitingInitialSessions)
        control("transport.state", .object(["state": .string("connected")]))
        XCTAssertTrue(state.isAwaitingInitialSessions, "Relay ready is not a Mac offline result")
        control("machine.presence", .bool(true))
        XCTAssertNil(state.bridgeReachable)
        XCTAssertTrue(state.isAwaitingInitialSessions, "Online Mac still needs its Bridge snapshot")
        reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: "snapshot", deviceId: "phone",
            machineId: "mac", sequence: 1, type: "session.snapshot",
            payload: .array([]))), into: &state)
        XCTAssertTrue(state.hasLoadedSessions)
        XCTAssertFalse(state.isAwaitingInitialSessions)
    }

    func testConfirmedOfflineAndFailuresRemainVisibleButReconnectClearsOldPresence() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: "offline", deviceId: "phone",
            machineId: "mac", sequence: 0, type: "machine.presence", payload: .bool(false))), into: &state)
        XCTAssertFalse(state.isAwaitingInitialSessions)
        reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: "retry", deviceId: "phone",
            machineId: "mac", sequence: 0, type: "transport.state",
            payload: .object(["state": .string("reconnecting"), "attempt": .number(1)]))), into: &state)
        XCTAssertNil(state.confirmedMachinePresence)
        XCTAssertTrue(state.isAwaitingInitialSessions)
        state.transportState = .failed("Connection failed")
        XCTAssertFalse(state.isAwaitingInitialSessions)
        state.transportState = .connected
        state.confirmedMachinePresence = true
        state.bridgeReachable = false
        XCTAssertFalse(state.isAwaitingInitialSessions)
    }

    @MainActor
    func testPairedLaunchTreatsTransactionRestoreAsConnectionPreparation() {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let model = makeModel(transport: DSHPreviewTransport(),
                                initialState: DSHStoreState(), isPaired: true)

        XCTAssertTrue(model.isPreparingInitialConnection,
                      "A paired launch must not flash the unreachable state before Relay starts")
    }

    func testStreamingHeadroomConsumesMeasuredGrowthBeforeRefilling() {
        var plan = DSHStreamingHeadroomPlan()
        plan.record(streamID: "stream-live", size: CGSize(width: 320, height: 50))
        let stableShell = try! XCTUnwrap(plan.reservedReplyHeight)
        XCTAssertEqual(plan.reservedHeight, 80, accuracy: 0.01)

        // A real 24pt wrap consumes the capacity.  The rendered outer row
        // remains the same height instead of making the scroll view advance.
        plan.record(streamID: "stream-live", size: CGSize(width: 320, height: 74))
        XCTAssertEqual(try! XCTUnwrap(plan.reservedReplyHeight), stableShell, accuracy: 0.01)
        let remaining = plan.reservedHeight
        plan.prepareForNextChunk(streamID: "stream-live")
        XCTAssertEqual(plan.reservedHeight, remaining, accuracy: 0.01,
                       "Do not refill after every wrapped line")

        // A transient Markdown reflow can shrink content; its capacity is
        // returned, keeping the outer shell stable and bounded.
        plan.record(streamID: "stream-live", size: CGSize(width: 320, height: 62))
        XCTAssertEqual(try! XCTUnwrap(plan.reservedReplyHeight), stableShell, accuracy: 0.01)

        // Completion clears all artificial height, even if the turn has not
        // yet emitted its final state update.
        plan.begin(streamID: nil)
        XCTAssertNil(plan.reservedReplyHeight)
        XCTAssertEqual(plan.reservedHeight, 0)

        // A rotation / Dynamic Type relayout starts a fresh measurement rather
        // than carrying a portrait estimate into the new width.  Very tall
        // content remains capped so no blank page can appear.
        plan.record(streamID: "stream-live", size: CGSize(width: 320, height: 50))
        plan.record(streamID: "stream-live", size: CGSize(width: 480, height: 20))
        XCTAssertEqual(plan.reservedHeight, 32, accuracy: 0.01)
        plan.record(streamID: "stream-next", size: CGSize(width: 480, height: 20))
        XCTAssertEqual(plan.streamID, "stream-next")
        XCTAssertEqual(plan.reservedHeight, 32, accuracy: 0.01,
                       "A new delta ID must not inherit the previous reply's capacity")
        var capped = DSHStreamingHeadroomPlan()
        capped.record(streamID: "stream-tall", size: CGSize(width: 320, height: 500))
        XCTAssertLessThanOrEqual(capped.reservedHeight, 96)
    }

    func testOnlyCurrentTransientStreamMessageCanReserveHeadroom() {
        let user = DSHChatMessage(id: "user", role: .user, markdown: "go", sequence: 10)
        let legacy = DSHChatMessage(id: "assistant-final", role: .assistant,
                                    markdown: "already durable", sequence: 11)
        XCTAssertNil(DSHStreamingMessageProjection.active(messages: [user, legacy], turnState: "running"))

        let oldTransient = DSHChatMessage(id: "stream-old", role: .assistant,
                                          markdown: "old", sequence: 9)
        XCTAssertNil(DSHStreamingMessageProjection.active(messages: [user, oldTransient], turnState: "running"))

        let live = DSHChatMessage(id: "stream-live", role: .assistant,
                                  markdown: "partial", sequence: 12)
        XCTAssertEqual(DSHStreamingMessageProjection.active(messages: [user, live], turnState: "running")?.streamID,
                       "stream-live")

        let completed = DSHChatMessage(id: "canonical", role: .assistant,
                                       markdown: "final", sequence: 12,
                                       replacesMessageId: "stream-live")
        XCTAssertNil(DSHStreamingMessageProjection.active(messages: [user, completed], turnState: "running"))
    }

    @MainActor
    func testStreamingCompletionKeepsCanonicalIDAndDoesNotResurrectPartialOnReplay() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        func apply(_ type: String, _ sequence: Int64, _ payload: [String: DSHJSONValue]) {
            reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: "e-\(sequence)", deviceId: "d", machineId: "m",
                sessionId: "s", sequence: sequence, type: type, payload: .object(payload))), into: &state)
        }
        apply("assistant.message.delta", 1, ["messageId": .string("partial"), "text": .string("Hello")])
        XCTAssertEqual(state.messagesBySession["s"]?.first?.markdown, "Hello")
        apply("assistant.message.delta", 2, ["messageId": .string("partial"), "text": .string(" world")])
        XCTAssertEqual(state.messagesBySession["s"]?.first?.markdown, "Hello world")
        reducer.reduce(historyEvent(type: "history.started", sequence: 3), into: &state)
        apply("assistant.reasoning", 4, ["messageId": .string("canonical"), "text": .string("Reasoning")])
        apply("assistant.message.completed", 5, ["id": .string("canonical"), "role": .string("assistant"),
            "markdown": .string("Hello world!"), "replacesMessageId": .string("partial")])
        reducer.reduce(historyEvent(type: "history.completed", sequence: 6), into: &state)
        XCTAssertEqual(state.messagesBySession["s"]?.map(\.id), ["canonical"])
        XCTAssertEqual(state.messagesBySession["s"]?.first?.markdown, "Hello world!")
        XCTAssertEqual(state.messagesBySession["s"]?.first?.reasoning, "Reasoning")
        XCTAssertEqual(state.messagesBySession["s"]?.first?.sequence, 1)
        apply("assistant.message.completed", 7, ["id": .string("canonical"), "role": .string("assistant"), "markdown": .string("Hello world!")])
        XCTAssertEqual(state.messagesBySession["s"]?.count, 1)
    }

    @MainActor
    func testAbandonedStreamIsRemovedFromLiveAndHistoryCarry() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: "d", deviceId: "d", machineId: "m", sessionId: "s", sequence: 1,
            type: "assistant.message.delta", payload: .object(["messageId": .string("partial"), "text": .string("obsolete")]))), into: &state)
        reducer.reduce(historyEvent(type: "history.started", sequence: 2), into: &state)
        reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: "x", deviceId: "d", machineId: "m", sessionId: "s", sequence: 3,
            type: "assistant.message.discarded", payload: .object(["messageId": .string("partial")]))), into: &state)
        reducer.reduce(historyEvent(type: "history.completed", sequence: 4), into: &state)
        XCTAssertTrue(state.messagesBySession["s", default: []].isEmpty)
    }

    @MainActor
    func testSessionBecomesUnreadOnlyAfterNewerActivity() {
        UserDefaults.standard.removeObject(forKey: DSHAppModel.lastReadSessionsKey)
        UserDefaults.standard.removeObject(forKey: DSHAppModel.unreadBaselineKey)
        defer {
            UserDefaults.standard.removeObject(forKey: DSHAppModel.lastReadSessionsKey)
            UserDefaults.standard.removeObject(forKey: DSHAppModel.unreadBaselineKey)
        }

        let model = DSHAppModel.preview()
        model.selectedSessionID = nil
        guard let session = model.sessions.first else {
            return XCTFail("Preview session is missing")
        }
        model.markSessionRead(session.id)
        XCTAssertFalse(model.isSessionUnread(session))

        var updated = session
        updated.updatedAt = Int64(Date().timeIntervalSince1970 * 1_000) + 1_000
        XCTAssertTrue(model.isSessionUnread(updated))
    }

    @MainActor
    func testConfirmedMessageHideSurvivesAViewModelReload() {
        UserDefaults.standard.removeObject(forKey: DSHAppModel.hiddenMessagesKey)
        defer { UserDefaults.standard.removeObject(forKey: DSHAppModel.hiddenMessagesKey) }

        let model = DSHAppModel.preview()
        model.hideMessage("preview-user", in: "preview-session")

        let visibleAfterDelete = model.transcriptEntries(for: "preview-session").flatMap { entry -> [String] in
            guard case .turn(let block) = entry else { return [] }
            return block.messages.map(\.id)
        }
        XCTAssertFalse(visibleAfterDelete.contains("preview-user"))

        let reloaded = DSHAppModel.preview()
        let visibleAfterReload = reloaded.transcriptEntries(for: "preview-session").flatMap { entry -> [String] in
            guard case .turn(let block) = entry else { return [] }
            return block.messages.map(\.id)
        }
        XCTAssertFalse(visibleAfterReload.contains("preview-user"))
        XCTAssertTrue(visibleAfterReload.contains("preview-assistant"))
    }

    func testReducerStreamsAssistantDeltaAndIgnoresDuplicateSequence() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        let first = DSHEvent(envelope: DSHEnvelope(messageId: "1", deviceId: "d", machineId: "m",
                                                   sessionId: "s", sequence: 1, type: "assistant.message.delta",
                                                   payload: .object(["messageId": .string("a"), "text": .string("Hel")])))
        let duplicate = DSHEvent(envelope: DSHEnvelope(messageId: "2", deviceId: "d", machineId: "m",
                                                       sessionId: "s", sequence: 1, type: "assistant.message.delta",
                                                       payload: .object(["messageId": .string("a"), "text": .string("lo")])))
        reducer.reduce(first, into: &state)
        reducer.reduce(duplicate, into: &state)
        XCTAssertEqual(state.lastSequence, 1)
        XCTAssertEqual(state.messagesBySession["s"]?.first?.markdown, "Hel")
    }

    @MainActor
    func testStreamingMarkdownRendererMatchesFullParserAcrossBlockBoundaries() {
        let chunks = [
            "Hello", " world", " with `inline", " code`", "\n\n# Heading", "\n",
            "\n- first", "\n- second", "\n\n```swift", "\nlet value = 1", "\n```",
            "\n\n| left | right |", "\n| --- | --- |", "\n| 1 | 2 |", " tail"
        ]
        var text = ""
        let renderer = DSHMarkdownBlockRenderer(text: text)

        for chunk in chunks {
            text += chunk
            renderer.update(text: text)
            XCTAssertEqual(renderer.blocks, DSHMarkdown.blocks(from: text),
                           "Incremental rendering diverged after chunk: \(chunk)")
        }

        let parseCountAfterChanges = renderer.parseCount
        renderer.update(text: text)
        XCTAssertEqual(renderer.parseCount, parseCountAfterChanges,
                       "An unchanged body pass must reuse its parsed blocks")

        // A stream's durable completion replaces the temporary text in the
        // same rendered row.  Its document must be parsed from the canonical
        // value, not a stale partial prefix.
        let canonical = "# Final\n\n```swift\nlet done = true\n```"
        renderer.update(text: canonical)
        XCTAssertEqual(renderer.blocks, DSHMarkdown.blocks(from: canonical))
        XCTAssertEqual(renderer.parseCount, parseCountAfterChanges + 1)
    }

    func testUnknownEventsAreRetained() {
        var state = DSHStoreState()
        let event = DSHEvent(envelope: DSHEnvelope(messageId: "u", deviceId: "d", machineId: "m",
                                                   sequence: 2, type: "new.event",
                                                   payload: .string("preserve me")))
        DSHEventReducer().reduce(event, into: &state)
        XCTAssertEqual(state.unknownEvents, [event.envelope])
    }

    func testConnectionReadyStartsANewSequenceEpochAfterBridgeRestart() {
        var state = DSHStoreState()
        state.lastSequence = 42
        let ready = DSHEvent(envelope: DSHEnvelope(
            messageId: "ready", deviceId: "d", machineId: "m", sequence: 1,
            type: "connection.ready", payload: .object([:])
        ))
        DSHEventReducer().reduce(ready, into: &state)
        XCTAssertEqual(state.lastSequence, 1)
        XCTAssertEqual(state.connectionState, .connected)
    }

    func testStaleLowerSnapshotCannotReplaceNewerAuthoritativeSessions() {
        var state = DSHStoreState()
        state.lastSequence = 42
        state.sessions = [DSHSessionSummary(id: "fresh", title: "Fresh", updatedAt: 42)]
        let stale = DSHEvent(envelope: DSHEnvelope(
            messageId: "replayed", deviceId: "d", machineId: "m", sequence: 3,
            type: "session.snapshot", payload: .array([
                .object(["id": .string("stale"), "title": .string("Stale"), "updatedAt": .number(3)]),
            ])
        ))

        DSHEventReducer().reduce(stale, into: &state)

        XCTAssertEqual(state.lastSequence, 42)
        XCTAssertEqual(state.sessions.map(\.id), ["fresh"])
    }

    func testCorrelatedLowerSnapshotStartsNewEpochAfterConnectorRestart() {
        var state = DSHStoreState()
        state.lastSequence = 42
        state.sessions = [DSHSessionSummary(id: "old", title: "Old", updatedAt: 42)]
        let fresh = DSHEvent(envelope: DSHEnvelope(
            messageId: "requested", deviceId: "d", machineId: "m", sequence: 1,
            type: "session.snapshot", payload: .array([
                .object(["id": .string("new"), "title": .string("New"), "updatedAt": .number(1)]),
            ])
        ), establishesSequenceEpoch: true)

        DSHEventReducer().reduce(fresh, into: &state)

        XCTAssertEqual(state.lastSequence, 1)
        XCTAssertEqual(state.sessions.map(\.id), ["new"])
        XCTAssertTrue(state.hasLoadedSessions)
    }

    func testRelayControlsUpdateReachabilityOutsideConnectorSequence() {
        var state = DSHStoreState()
        state.lastSequence = 42
        state.transportState = .connected
        state.machineOnline = true
        state.connectionState = .connected

        let reconnecting = DSHEvent(envelope: DSHEnvelope(
            messageId: "transport", deviceId: "d", machineId: "m", sequence: 0,
            type: "transport.state",
            payload: .object(["state": .string("reconnecting"), "attempt": .number(1)])
        ))
        DSHEventReducer().reduce(reconnecting, into: &state)
        XCTAssertEqual(state.lastSequence, 42)
        XCTAssertEqual(state.transportState, .reconnecting(attempt: 1))
        XCTAssertFalse(state.machineOnline)
        XCTAssertNil(state.bridgeReachable)

        let relayConnected = DSHEvent(envelope: DSHEnvelope(
            messageId: "relay", deviceId: "d", machineId: "m", sequence: 0,
            type: "transport.state", payload: .object(["state": .string("connected")])
        ))
        let machineOnline = DSHEvent(envelope: DSHEnvelope(
            messageId: "presence", deviceId: "d", machineId: "m", sequence: 0,
            type: "machine.presence", payload: .bool(true)
        ))
        DSHEventReducer().reduce(relayConnected, into: &state)
        DSHEventReducer().reduce(machineOnline, into: &state)
        XCTAssertEqual(state.lastSequence, 42)
        XCTAssertEqual(state.transportState, .connected)
        XCTAssertTrue(state.machineOnline)
        XCTAssertNil(state.bridgeReachable)
        XCTAssertEqual(state.connectionState, .connected)
    }

    func testBridgeFailureOverridesConnectorPresenceUntilBridgeRecovers() {
        var state = DSHStoreState()
        state.transportState = .connected
        state.machineOnline = true
        let reducer = DSHEventReducer()
        let failure = DSHEvent(envelope: DSHEnvelope(
            messageId: "failed", deviceId: "d", machineId: "m", sequence: 1,
            type: "protocol.error",
            payload: .object([
                "code": .string("bridge-request-failed"),
                "message": .string("Local DSH bridge request failed"),
                "retryable": .bool(true),
            ])
        ))
        reducer.reduce(failure, into: &state)
        XCTAssertEqual(state.bridgeReachable, false)

        let ready = DSHEvent(envelope: DSHEnvelope(
            messageId: "ready-again", deviceId: "d", machineId: "m", sequence: 2,
            type: "connection.ready", payload: .object([:])
        ))
        reducer.reduce(ready, into: &state)
        XCTAssertEqual(state.bridgeReachable, true)
    }

    func testAuthoritativeSnapshotStartsANewSequenceEpochAfterConnectorRestart() {
        var state = DSHStoreState()
        state.lastSequence = 42
        state.sessions = [DSHSessionSummary(id: "stale", title: "Stale", updatedAt: 1)]
        let snapshot = DSHEvent(envelope: DSHEnvelope(
            messageId: "snapshot", deviceId: "d", machineId: "m", sequence: 1,
            type: "session.snapshot", payload: .array([
                .object(["id": .string("current"), "title": .string("Current"), "updatedAt": .number(2)]),
            ])
        ), establishesSequenceEpoch: true)
        DSHEventReducer().reduce(snapshot, into: &state)
        XCTAssertEqual(state.lastSequence, 1)
        XCTAssertEqual(state.sessions.map(\.id), ["current"])
    }

    func testApprovalResolvesExactlyOnce() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        let requested = DSHEvent(envelope: DSHEnvelope(messageId: "a", deviceId: "d", machineId: "m",
                                                        sessionId: "s", sequence: 1, type: "approval.requested",
                                                        payload: .object(["id": .string("approval"), "sessionId": .string("s"),
                                                                         "toolName": .string("shell"), "reason": .string("run")])))
        let resolved = DSHEvent(envelope: DSHEnvelope(messageId: "b", deviceId: "d", machineId: "m",
                                                       sessionId: "s", sequence: 2, type: "approval.resolved",
                                                       payload: .object(["id": .string("approval"), "allowed": .bool(false)])))
        reducer.reduce(requested, into: &state); reducer.reduce(resolved, into: &state)
        XCTAssertTrue(state.pendingApprovals.isEmpty)
    }

    func testQuestionAskedSurvivesUntilTheBridgeResolvesIt() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        let asked = DSHEvent(envelope: DSHEnvelope(
            messageId: "q", deviceId: "d", machineId: "m", sessionId: "s", sequence: 1,
            type: "question.asked",
            payload: .object([
                "id": .string("question_1"),
                "sessionId": .string("s"),
                "questions": .array([
                    .object([
                        "id": .string("mode"),
                        "question": .string("Which mode?"),
                        "options": .array([
                            .object(["label": .string("Fast")]),
                            .object(["label": .string("Careful")]),
                        ]),
                    ]),
                ]),
            ])
        ))
        reducer.reduce(asked, into: &state)

        // The tappable options must survive decoding, since they are the whole
        // point of answering from the phone.
        XCTAssertEqual(state.pendingQuestions.count, 1)
        XCTAssertEqual(state.pendingQuestions.first?.questions.first?.options?.map(\.label),
                       ["Fast", "Careful"])

        // A replayed duplicate must not stack a second card.
        reducer.reduce(asked, into: &state)
        XCTAssertEqual(state.pendingQuestions.count, 1)

        let resolved = DSHEvent(envelope: DSHEnvelope(
            messageId: "q2", deviceId: "d", machineId: "m", sessionId: "s", sequence: 2,
            type: "question.resolved",
            payload: .object(["id": .string("question_1"), "sessionId": .string("s")])
        ))
        reducer.reduce(resolved, into: &state)
        XCTAssertTrue(state.pendingQuestions.isEmpty)
    }

    func testReasoningIsKeptOutOfTheAnswerAndSurvivesCompletion() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        let reasoning = DSHEvent(envelope: DSHEnvelope(
            messageId: "r", deviceId: "d", machineId: "m", sessionId: "s", sequence: 1,
            type: "assistant.reasoning",
            payload: .object(["messageId": .string("a"), "text": .string("Let me think.")])
        ))
        let completed = DSHEvent(envelope: DSHEnvelope(
            messageId: "c", deviceId: "d", machineId: "m", sessionId: "s", sequence: 2,
            type: "assistant.message.completed",
            payload: .object(["id": .string("a"), "role": .string("assistant"), "markdown": .string("The answer.")])
        ))
        reducer.reduce(reasoning, into: &state)
        reducer.reduce(completed, into: &state)

        let message = state.messagesBySession["s"]?.first
        XCTAssertEqual(message?.markdown, "The answer.")
        // Completion replaces the streaming partial, so it must carry the
        // reasoning forward rather than dropping it.
        XCTAssertEqual(message?.reasoning, "Let me think.")
    }

    func testSessionsOutsideEveryWorkspaceAreNotListed() {
        let sessions = [
            DSHSessionSummary(id: "a", title: "Real work", updatedAt: 30, workspaceName: "project-a"),
            DSHSessionSummary(id: "b", title: "Loose one", updatedAt: 20, cwd: "/tmp/one"),
            DSHSessionSummary(id: "c", title: "Loose two", updatedAt: 10, cwd: "/tmp/two"),
        ]

        let groups = sessions.groupedForList(.byWorkspace, showArchived: false)

        // They must not invent one workspace per directory *nor* collect into an
        // "Other" bucket: delegated subagent runs have no workspace either, so
        // that bucket mixed junk with real sessions.
        XCTAssertEqual(groups.map(\.title), ["project-a"])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["a"])
    }

    func testFlatModeAlsoOmitsSessionsWithNoWorkspace() {
        let sessions = [
            DSHSessionSummary(id: "a", title: "Real work", updatedAt: 30, workspaceName: "project-a"),
            DSHSessionSummary(id: "b", title: "Loose one", updatedAt: 40, cwd: "/tmp/one"),
        ]

        let groups = sessions.groupedForList(.flat, showArchived: false)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].sessions.map(\.id), ["a"])
    }

    func testFlatGroupingKeepsOneRecencySortedList() {
        let sessions = [
            DSHSessionSummary(id: "old", title: "Old", updatedAt: 1, workspaceName: "z"),
            DSHSessionSummary(id: "new", title: "New", updatedAt: 9, workspaceName: "a"),
        ]

        let groups = sessions.groupedForList(.flat, showArchived: false)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].sessions.map(\.id), ["new", "old"])
    }

    func testGroupingHonoursTheArchiveFilter() {
        let sessions = [
            DSHSessionSummary(id: "live", title: "Live", updatedAt: 2, workspaceName: "w"),
            DSHSessionSummary(id: "gone", title: "Gone", updatedAt: 1, workspaceName: "w", archived: true),
        ]

        XCTAssertEqual(sessions.groupedForList(.byWorkspace, showArchived: false)[0].sessions.map(\.id), ["live"])
        XCTAssertEqual(sessions.groupedForList(.byWorkspace, showArchived: true)[0].sessions.map(\.id), ["live", "gone"])
        XCTAssertTrue(sessions.filter { $0.archived == true }.groupedForList(.byWorkspace, showArchived: false).isEmpty)
    }

    func testWorkspaceOptionsAreDedupedAndSorted() {
        let sessions = [
            DSHSessionSummary(id: "a", title: "A", updatedAt: 3, workspaceId: "ws-b", workspaceName: "beta"),
            DSHSessionSummary(id: "b", title: "B", updatedAt: 2, workspaceId: "ws-a", workspaceName: "Alpha"),
            DSHSessionSummary(id: "c", title: "C", updatedAt: 1, workspaceId: "ws-b", workspaceName: "beta"),
            // Unfiled sessions contribute nothing to the picker.
            DSHSessionSummary(id: "d", title: "D", updatedAt: 0, cwd: "/tmp"),
        ]

        let options = sessions.workspaceOptions()

        XCTAssertEqual(options.map(\.id), ["ws-a", "ws-b"])
        XCTAssertEqual(options.map(\.name), ["Alpha", "beta"])
    }

    func testWorkspaceGroupsUseStableRegistryIDsForMutations() {
        let sessions = [
            DSHSessionSummary(id: "a", title: "A", updatedAt: 2,
                              workspaceId: "workspace-1", workspaceName: "Renamable"),
            DSHSessionSummary(id: "b", title: "B", updatedAt: 1,
                              workspaceId: "workspace-1", workspaceName: "Renamable"),
        ]

        let groups = sessions.groupedForList(.byWorkspace, showArchived: false)

        XCTAssertEqual(groups.map(\.id), ["workspace-1"])
        XCTAssertEqual(groups.map(\.title), ["Renamable"])
    }

    func testModelChangeIsStoredAsInlineTranscriptEntry() {
        var state = DSHStoreState()
        let event = DSHEvent(envelope: DSHEnvelope(
            messageId: "model-change", deviceId: "d", machineId: "m", sessionId: "s", sequence: 2,
            type: "session.model.changed",
            payload: .object([
                "sessionId": .string("s"),
                "previous": .object(["provider": .string("deepseek"), "model": .string("v4.1-flash")]),
                "current": .object(["provider": .string("deepseek"), "model": .string("v4.1-reasoner")]),
            ])
        ))

        DSHEventReducer().reduce(event, into: &state)
        let notice = try! XCTUnwrap(state.modelChangesBySession["s"]?.first)
        XCTAssertEqual(notice.sequence, 2)
        XCTAssertEqual(notice.previous?.model, "v4.1-flash")
        XCTAssertEqual(notice.current.model, "v4.1-reasoner")

        let entries = [DSHChatMessage(id: "answer", role: .assistant, markdown: "ok", sequence: 3)]
            .transcriptEntries(with: [], modelChanges: [notice])
        XCTAssertEqual(entries.map(\.id), ["model-change-s-2-deepseek-v4.1-reasoner", "turn-answer"])
    }

    func testModelChangesBeforeOneSendCollapseToTheFinalChoice() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()

        reducer.reduce(modelChangeEvent(model: "draft", sequence: 1), into: &state)
        reducer.reduce(modelChangeEvent(model: "balanced", sequence: 2), into: &state)
        reducer.reduce(modelChangeEvent(model: "focused", sequence: 3), into: &state)

        let notices = state.modelChangesBySession["s"] ?? []
        XCTAssertEqual(notices.map(\.current.model), ["focused"])
        XCTAssertEqual(notices.map(\.sequence), [3])
    }

    func testModelChangesAfterAcceptedSendStartANewNoticeBatch() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()

        reducer.reduce(modelChangeEvent(model: "draft", sequence: 1), into: &state)
        reducer.reduce(modelChangeEvent(model: "balanced", sequence: 2), into: &state)
        reducer.reduce(userMessageEvent(id: "question", text: "send this", sequence: 3), into: &state)
        reducer.reduce(modelChangeEvent(model: "focused", sequence: 4), into: &state)
        reducer.reduce(modelChangeEvent(model: "max", sequence: 5), into: &state)

        let notices = state.modelChangesBySession["s"] ?? []
        XCTAssertEqual(notices.map(\.current.model), ["balanced", "max"])
        XCTAssertEqual(notices.map(\.sequence), [2, 5])

        let entries = state.messagesBySession["s", default: []]
            .transcriptEntries(with: [], modelChanges: notices)
        XCTAssertEqual(entries.map(\.id), [
            "model-change-s-2-provider-balanced",
            "turn-question",
            "model-change-s-5-provider-max",
        ])
    }

    func testPermissionUpdateChangesSessionStateWithoutAddingTranscriptNotice() {
        var state = DSHStoreState()
        state.sessions = [DSHSessionSummary(id: "s", permissionMode: "read-only")]
        let event = DSHEvent(envelope: DSHEnvelope(
            messageId: "permission", deviceId: "d", machineId: "m", sessionId: "s", sequence: 1,
            type: "permission.updated",
            payload: .object([
                "sessionId": .string("s"),
                "mode": .string("danger-full-access"),
            ])
        ))

        DSHEventReducer().reduce(event, into: &state)

        XCTAssertEqual(state.permissionBySession["s"]?.mode, "danger-full-access")
        XCTAssertEqual(state.sessions.first?.permissionMode, "danger-full-access")
        XCTAssertTrue(state.messagesBySession["s", default: []].isEmpty)
        XCTAssertTrue(state.modelChangesBySession["s", default: []].isEmpty)
        XCTAssertTrue(state.messagesBySession["s", default: []]
            .transcriptEntries(with: [], modelChanges: state.modelChangesBySession["s", default: []])
            .isEmpty)
    }

    func testHistoricalPermissionSetupSuccessDoesNotCreateTranscriptCommand() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()

        reducer.reduce(commandResultEvent(kind: "success", text: "preset workspace-write", sequence: 1), into: &state)

        XCTAssertTrue(state.commandResultsBySession["s", default: []].isEmpty)
    }

    func testHistoricalPermissionSetupFailureRemainsVisible() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()

        reducer.reduce(commandResultEvent(kind: "error", text: "preset workspace-write", sequence: 1), into: &state)

        let result = try! XCTUnwrap(state.commandResultsBySession["s"]?.first)
        XCTAssertEqual(result.kind, "error")
        XCTAssertEqual(result.text, "preset workspace-write")
    }

    func testReplayedModelChangeWithSameIdentityDoesNotEraseNewDraft() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()

        reducer.reduce(modelChangeEvent(model: "first", sequence: 2), into: &state)
        reducer.reduce(userMessageEvent(id: "question", text: "send this", sequence: 3), into: &state)
        reducer.reduce(modelChangeEvent(model: "next", sequence: 4), into: &state)
        reducer.reduce(sessionSnapshotEvent(sequence: 1), into: &state)
        reducer.reduce(modelChangeEvent(model: "first", sequence: 2), into: &state)

        let notices = state.modelChangesBySession["s"] ?? []
        XCTAssertEqual(notices.map(\.current.model), ["first", "next"])
        XCTAssertEqual(notices.map(\.sequence), [2, 4])
    }

    func testHistoryReplayModelChangeMergesWithCarryWithoutDuplicate() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()

        reducer.reduce(modelChangeEvent(model: "first", sequence: 1), into: &state)
        reducer.reduce(userMessageEvent(id: "question", text: "send this", sequence: 2), into: &state)
        reducer.reduce(modelChangeEvent(model: "next", sequence: 3), into: &state)
        reducer.reduce(historyEvent(type: "history.started", sequence: 4), into: &state)
        // History envelopes are newly sequenced. Its payload nevertheless
        // represents the first, already rendered model change.
        reducer.reduce(modelChangeEvent(model: "first", sequence: 5), into: &state)
        reducer.reduce(historyEvent(type: "history.completed", sequence: 6), into: &state)

        let notices = state.modelChangesBySession["s"] ?? []
        XCTAssertEqual(notices.map(\.current.model), ["first", "next"])
        XCTAssertEqual(notices.map(\.sequence), [1, 3])
    }

    func testTranscriptInterleavesMessagesAndToolCallsByArrival() {
        // A message, then a call, then another message — the shape of a real
        // turn. Rendering messages and tools as two runs put the call last.
        let messages = [
            DSHChatMessage(id: "m1", role: .assistant, markdown: "reading", sequence: 2),
            DSHChatMessage(id: "m2", role: .assistant, markdown: "done", sequence: 4),
        ]
        let tools = [
            DSHToolActivity(id: "bash-1", name: "bash", status: "succeeded", detail: "ok", sequence: 3),
        ]

        let entries = messages.transcriptEntries(with: tools)

        XCTAssertEqual(entries.map(\.id), ["turn-m1", "tool-bash-1", "turn-m2"])
    }

    func testMissingSequencesFallBackToArrivalOrderInsteadOfIDOrder() {
        // State persisted before sequences existed carries none at all. Any
        // arbitrary tie-break (id order, say) would scramble the transcript, so
        // ties must keep the order the arrays already hold.
        let messages = [
            DSHChatMessage(id: "zzz", role: .user, markdown: "first"),
            DSHChatMessage(id: "aaa", role: .assistant, markdown: "second"),
        ]

        let entries = messages.transcriptEntries(with: [])

        XCTAssertEqual(entries.map(\.id), ["turn-zzz", "turn-aaa"])
    }

    func testToolCallWithoutASequenceStillLandsAfterEarlierMessages() {
        let messages = [DSHChatMessage(id: "m1", role: .assistant, markdown: "x", sequence: 5)]
        let tools = [DSHToolActivity(id: "t1", name: "bash")]

        let entries = messages.transcriptEntries(with: tools)

        // 0 < 5, so the unsequenced call sorts before the sequenced message.
        XCTAssertEqual(entries.map(\.id), ["tool-t1", "turn-m1"])
    }

    func testCommandResultIsStampedAndInterleavedInsteadOfPinnedToBottom() {
        var state = DSHStoreState()
        let command = DSHEvent(envelope: DSHEnvelope(
            messageId: "command-event", deviceId: "d", machineId: "m", sessionId: "s", sequence: 2,
            type: "command.result",
            payload: .object([
                "sessionId": .string("s"),
                "requestId": .string("command-1"),
                "matched": .bool(true),
                "text": .string("done"),
            ])
        ))
        DSHEventReducer().reduce(command, into: &state)

        let result = try! XCTUnwrap(state.commandResultsBySession["s"]?.first)
        XCTAssertEqual(result.sequence, 2)

        let messages = [
            DSHChatMessage(id: "before", role: .user, markdown: "before", sequence: 1),
            DSHChatMessage(id: "after", role: .assistant, markdown: "after", sequence: 3),
        ]
        let entries = messages.transcriptEntries(with: [], commandResults: [result])

        XCTAssertEqual(entries.map(\.id), ["turn-before", "command-command-1", "turn-after"])
    }

    // MARK: - History replay brackets

    private func historyEvent(type: String, sessionId: String = "s",
                              sequence: Int64, batchId: String = "b1") -> DSHEvent {
        DSHEvent(envelope: DSHEnvelope(
            messageId: "evt-\(sequence)", deviceId: "d", machineId: "m",
            sessionId: sessionId, sequence: sequence, type: type,
            payload: .object([
                "sessionId": .string(sessionId),
                "batchId": .string(batchId),
            ])
        ))
    }

    private func userMessageEvent(id: String, text: String, sequence: Int64,
                                  sessionId: String = "s") -> DSHEvent {
        DSHEvent(envelope: DSHEnvelope(
            messageId: "evt-\(sequence)", deviceId: "d", machineId: "m",
            sessionId: sessionId, sequence: sequence, type: "user.message.accepted",
            payload: .object([
                "id": .string(id),
                "role": .string("user"),
                "markdown": .string(text),
            ])
        ))
    }

    private func modelChangeEvent(model: String, sequence: Int64,
                                  sessionId: String = "s") -> DSHEvent {
        DSHEvent(envelope: DSHEnvelope(
            messageId: "model-\(sequence)", deviceId: "d", machineId: "m",
            sessionId: sessionId, sequence: sequence, type: "session.model.changed",
            payload: .object([
                "sessionId": .string(sessionId),
                "current": .object([
                    "provider": .string("provider"),
                    "model": .string(model),
                ]),
            ])
        ))
    }

    private func commandResultEvent(kind: String, text: String, sequence: Int64,
                                    sessionId: String = "s") -> DSHEvent {
        DSHEvent(envelope: DSHEnvelope(
            messageId: "command-\(sequence)", deviceId: "d", machineId: "m",
            sessionId: sessionId, sequence: sequence, type: "command.result",
            payload: .object([
                "sessionId": .string(sessionId),
                "requestId": .string("request-\(sequence)"),
                "matched": .bool(true),
                "kind": .string(kind),
                "text": .string(text),
            ])
        ))
    }

    private func sessionSnapshotEvent(sequence: Int64) -> DSHEvent {
        DSHEvent(envelope: DSHEnvelope(
            messageId: "snapshot-\(sequence)", deviceId: "d", machineId: "m",
            sequence: sequence, type: "session.snapshot", payload: .array([])
        ))
    }

    private func toolStartedEvent(id: String, sequence: Int64,
                                  sessionId: String = "s") -> DSHEvent {
        DSHEvent(envelope: DSHEnvelope(
            messageId: "evt-\(sequence)", deviceId: "d", machineId: "m",
            sessionId: sessionId, sequence: sequence, type: "tool.started",
            payload: .object([
                "id": .string(id),
                "name": .string("bash"),
                "status": .string("running"),
            ])
        ))
    }

    func testHistoryReplayMergesWithoutClearing() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        // Live rows seen before the replay: unpersisted output.
        reducer.reduce(userMessageEvent(id: "live-q", text: "live?", sequence: 1), into: &state)
        reducer.reduce(toolStartedEvent(id: "live-t", sequence: 2), into: &state)
        XCTAssertEqual(state.messagesBySession["s"]?.map(\.id), ["live-q"])

        // The replay must NOT blank the arrays: replayed rows merge by id
        // (dupes are no-ops), so the screen never flashes empty mid-replay.
        reducer.reduce(historyEvent(type: "history.started", sequence: 3), into: &state)
        XCTAssertEqual(state.messagesBySession["s"]?.map(\.id), ["live-q"])
        XCTAssertEqual(state.historyCarryOverBySession["s"]?.batchId, "b1")
        XCTAssertEqual(state.historyCarryOverBySession["s"]?.messages.map(\.id), ["live-q"])
        XCTAssertEqual(state.historyCarryOverBySession["s"]?.tools.map(\.id), ["live-t"])

        reducer.reduce(userMessageEvent(id: "h-q", text: "old?", sequence: 4), into: &state)
        reducer.reduce(toolStartedEvent(id: "h-t", sequence: 5), into: &state)
        reducer.reduce(historyEvent(type: "history.completed", sequence: 6), into: &state)

        // Live rows keep their place; replayed rows append; carry (already
        // present) merges as a no-op. Render order comes from the sequence
        // sort, not array order.
        XCTAssertEqual(state.messagesBySession["s"]?.map(\.id), ["live-q", "h-q"])
        XCTAssertEqual(state.toolsBySession["s"]?.map(\.id), ["live-t", "h-t"])
        XCTAssertNil(state.historyCarryOverBySession["s"])
        // The replay must not renumber the live rows.
        XCTAssertEqual(state.messagesBySession["s"]?.first?.sequence, 1)
    }

    func testHistoryCompletionWithStaleBatchIdIsIgnored() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        reducer.reduce(historyEvent(type: "history.started", sequence: 1, batchId: "b1"),
                       into: &state)
        // A completion from an overlapping older batch must not merge.
        reducer.reduce(historyEvent(type: "history.completed", sequence: 2, batchId: "b0"),
                       into: &state)
        XCTAssertNotNil(state.historyCarryOverBySession["s"])
    }

    func testHistoryForceMergeIgnoresBatchId() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        reducer.reduce(userMessageEvent(id: "live-q", text: "live?", sequence: 1), into: &state)
        reducer.reduce(historyEvent(type: "history.started", sequence: 2, batchId: "b1"), into: &state)
        reducer.reduce(userMessageEvent(id: "h-q", text: "old?", sequence: 3), into: &state)
        // Timeout path: merge whatever is open (carry rows already present
        // merge as no-ops).
        reducer.completeHistory(sessionId: "s", batchId: nil, into: &state)
        XCTAssertEqual(state.messagesBySession["s"]?.map(\.id), ["live-q", "h-q"])
        XCTAssertNil(state.historyCarryOverBySession["s"])
    }

    func testHistoricalPermissionAndMetadataDoNotRollBackLiveProjection() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        func event(type: String, sequence: Int64, historyBatchId: String?,
                   payload: [String: DSHJSONValue]) -> DSHEvent {
            DSHEvent(envelope: DSHEnvelope(
                messageId: "config-(sequence)", deviceId: "d", machineId: "m",
                sessionId: "s", historyBatchId: historyBatchId, sequence: sequence,
                type: type, payload: .object(payload)))
        }

        reducer.reduce(event(type: "permission.updated", sequence: 1, historyBatchId: nil,
                             payload: ["sessionId": .string("s"),
                                       "mode": .string("danger-full-access")]), into: &state)
        reducer.reduce(event(type: "session.metadata.updated", sequence: 2, historyBatchId: nil,
                             payload: ["sessionId": .string("s"),
                                       "provider": .string("provider-b"),
                                       "model": .string("model-b"),
                                       "reasoningEffort": .string("high")]), into: &state)

        reducer.reduce(event(type: "permission.updated", sequence: 3, historyBatchId: "old-batch",
                             payload: ["sessionId": .string("s"),
                                       "mode": .string("read-only")]), into: &state)
        reducer.reduce(event(type: "session.metadata.updated", sequence: 4, historyBatchId: "old-batch",
                             payload: ["sessionId": .string("s"),
                                       "provider": .string("provider-a"),
                                       "model": .string("model-a"),
                                       "reasoningEffort": .string("low")]), into: &state)

        XCTAssertEqual(state.permissionBySession["s"]?.mode, "danger-full-access")
        XCTAssertEqual(state.metadataBySession["s"]?.provider, "provider-b")
        XCTAssertEqual(state.metadataBySession["s"]?.model, "model-b")
        XCTAssertEqual(state.metadataBySession["s"]?.reasoningEffort, "high")
    }

    func testOverlappingReplaysDoNotLoseRows() {
        // A second open while the first replay still streams must fold into
        // the open carry, not replace it: replacing discards rows outside
        // the replay window, and the first completion then drops them for
        // good (transcript goes blank except for freshly streamed rows).
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        reducer.reduce(userMessageEvent(id: "old", text: "old?", sequence: 1), into: &state)
        reducer.reduce(historyEvent(type: "history.started", sequence: 2, batchId: "b1"), into: &state)
        reducer.reduce(userMessageEvent(id: "r1", text: "replayed?", sequence: 3), into: &state)
        reducer.reduce(historyEvent(type: "history.started", sequence: 4, batchId: "b2"), into: &state)
        reducer.reduce(userMessageEvent(id: "r2", text: "replayed?", sequence: 5), into: &state)
        reducer.reduce(historyEvent(type: "history.completed", sequence: 6, batchId: "b1"), into: &state)
        reducer.reduce(historyEvent(type: "history.completed", sequence: 7, batchId: "b2"), into: &state)
        // Render order comes from the sequence sort, so compare as a set.
        XCTAssertEqual(state.messagesBySession["s"]?.map(\.id).sorted(), ["old", "r1", "r2"])
        XCTAssertNil(state.historyCarryOverBySession["s"])
    }

    func testAttachmentCacheEvictsOldestFirst() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, bytes: Int, age: TimeInterval) throws {
            let url = dir.appendingPathComponent(name)
            try Data(repeating: 0x41, count: bytes).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)],
                ofItemAtPath: url.path)
        }
        try write("old.bin", bytes: 100, age: 100)
        try write("new.bin", bytes: 100, age: 0)
        DSHAppModel.evictAttachmentCache(directory: dir, keepingBytesUnder: 150)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("old.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("new.bin").path))
        // Under budget: nothing is touched.
        DSHAppModel.evictAttachmentCache(directory: dir, keepingBytesUnder: 10_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("new.bin").path))
    }

    @MainActor
    func testQueuedPromptHoldEditCancelTake() {
        // Unique session id: the queue persists to UserDefaults per machine,
        // so a fixed id would leak entries across test runs.
        let sid = "q-\(UUID().uuidString)"
        let model = makeModel(transport: DSHPreviewTransport(), initialState: DSHStoreState(), isPaired: true)
        model.holdQueuedPrompt(text: "  first  ", for: sid)
        model.holdQueuedPrompt(text: "second", for: sid)
        XCTAssertEqual(model.queuedPrompts(for: sid).map(\.text), ["first", "second"])
        let first = model.queuedPrompts(for: sid)[0]
        XCTAssertFalse(first.sent)
        model.updateQueuedPrompt(id: first.id, text: "first-edited", sessionID: sid)
        XCTAssertEqual(model.queuedPrompts(for: sid).first?.text, "first-edited")
        XCTAssertTrue(model.cancelQueuedPrompt(id: first.id, sessionID: sid))
        XCTAssertEqual(model.queuedPrompts(for: sid).map(\.text), ["second"])
        // A broadcast/history message with the same text cannot consume an
        // entry that has not been sent yet.
        model.holdQueuedPrompt(text: "server", for: sid)
        model.matchQueuedPrompt(text: "server", sessionID: sid, requestID: "other-request")
        XCTAssertTrue(model.queuedPrompts(for: sid).contains(where: { !$0.sent && $0.text == "server" }))
        // Server-sent mirrors refuse local cancel; acceptance still retires.
        let queuedRequestID = "queued-\(UUID().uuidString)"
        model.noteQueuedPrompt(text: "server", mode: "queue", requestId: queuedRequestID, for: sid)
        let server = model.queuedPrompts(for: sid).first(where: { $0.sent && $0.requestId == queuedRequestID })!
        XCTAssertTrue(server.sent)
        XCTAssertFalse(model.cancelQueuedPrompt(id: server.id, sessionID: sid))
        model.matchQueuedPrompt(text: "server", sessionID: sid, requestID: queuedRequestID)
        let second = model.queuedPrompts(for: sid).first(where: { $0.text == "second" })!
        XCTAssertEqual(model.takeQueuedPrompt(id: second.id, sessionID: sid)?.text, "second")
        let heldServer = model.queuedPrompts(for: sid).first(where: { !$0.sent && $0.text == "server" })!
        XCTAssertTrue(model.cancelQueuedPrompt(id: heldServer.id, sessionID: sid))
        XCTAssertTrue(model.queuedPrompts(for: sid).isEmpty)
    }

    @MainActor
    func testQueuedPromptPreservesFullBodyBeyondPreviewLength() {
        let sid = "q-long-\(UUID().uuidString)"
        let body = String(repeating: "界", count: 2_001)
        let model = makeModel(transport: DSHPreviewTransport(), initialState: DSHStoreState(), isPaired: true)
        model.holdQueuedPrompt(text: body, for: sid)
        XCTAssertEqual(model.queuedPrompts(for: sid).first?.text, body)
        let item = model.queuedPrompts(for: sid).first!
        XCTAssertEqual(model.takeQueuedPrompt(id: item.id, sessionID: sid)?.text, body)
    }

    @MainActor
    func testPendingSendMatchParkAndRetry() {
        let sid = "send-\(UUID().uuidString)"
        let model = makeModel(transport: DSHPreviewTransport(), initialState: DSHStoreState(), isPaired: true)
        // Sending records a pending ack; acceptance retires it.
        model.sendPrompt("hello", to: sid)
        XCTAssertEqual(model.pendingSendCount(for: sid), 1)
        model.confirmPendingSend(text: "hello", sessionID: sid)
        XCTAssertEqual(model.pendingSendCount(for: sid), 0)
        XCTAssertNil(model.failedSend)
        // A transport throw parks the prompt with its text for retry.
        let command = DSHCommand(
            requestId: "req-1", deviceId: "d", machineId: "m", sessionId: sid,
            type: "prompt.send",
            payload: .object(["text": .string("retry me"),
                              "attachments": .array([])]))
        model.parkFailedPromptSend(command, error: NSError(domain: "test", code: 1))
        XCTAssertEqual(model.failedSend?.text, "retry me")
        XCTAssertEqual(model.failedSend?.sessionID, sid)
        // Retry clears the banner and re-records a fresh pending send.
        model.retryFailedSend()
        XCTAssertNil(model.failedSend)
        XCTAssertEqual(model.pendingSendCount(for: sid), 1)
        model.dismissFailedSend()
    }

    @MainActor
    func testSessionCreationFailureRetainsRequestIdentityForRetry() async {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport(failingTypes: ["session.create"])
        let model = makeModel(transport: transport, initialState: DSHStoreState(), isPaired: true)
        let workspace = DSHWorkspaceOption(id: "workspace", name: "Workspace")

        XCTAssertTrue(model.createSession(in: workspace, mode: "standard",
                                          initialPrompt: "keep this draft"))
        try? await Task.sleep(for: .milliseconds(60))

        let requestID = try! XCTUnwrap(model.lastSessionCreationRequestID)
        XCTAssertEqual(model.sessionCreationFailure(for: requestID)?.id, requestID)
        XCTAssertEqual(model.sessionCreationFailure(for: requestID)?.detail,
                       "The Relay WebSocket is not connected.")
        let firstCommand = await transport.lastCommand(ofType: "session.create")
        XCTAssertEqual(firstCommand?.requestId, requestID)

        model.sessionCreationAckTimeout = 1
        model.retrySessionCreation(requestID: requestID)
        try? await Task.sleep(for: .milliseconds(60))
        let retryCommand = await transport.lastCommand(ofType: "session.create")
        XCTAssertEqual(retryCommand?.requestId, requestID,
                       "Retry must reuse the original create identity")
    }

    @MainActor
    func testSessionCreationTimeoutBecomesRecoverableAndOldTimerCannotFailRetry() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: DSHStoreState(), isPaired: true)
        model.sessionCreationAckTimeout = 0.12
        model.connect()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(model.createSession(mode: "standard", initialPrompt: "draft"))
        let requestID = try XCTUnwrap(model.lastSessionCreationRequestID)
        try await Task.sleep(for: .milliseconds(70))
        model.retrySessionCreation(requestID: requestID)

        // The first attempt's timer has now expired, but the retry is still
        // inside its own acknowledgement window.
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertNil(model.sessionCreationFailure(for: requestID))
        let retryCommand = await transport.lastCommand(ofType: "session.create")
        XCTAssertEqual(retryCommand?.requestId, requestID)

        try await Task.sleep(for: .milliseconds(90))
        XCTAssertTrue(model.sessionCreationFailure(for: requestID)?.resultUnknown == true)
        model.disconnect()
    }

    @MainActor
    func testUnknownCreateCanBeKeptWhileEditingAndLateResultStillSettlesOriginal() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: DSHStoreState(), isPaired: true)
        model.sessionCreationAckTimeout = 0.04
        model.connect()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(model.createSession(mode: "standard", initialPrompt: "original"))
        let originalID = try XCTUnwrap(model.lastSessionCreationRequestID)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertTrue(model.sessionCreationFailure(for: originalID)?.resultUnknown == true)

        model.retainSessionCreationForEditing(requestID: originalID)
        XCTAssertTrue(model.createSession(mode: "standard", initialPrompt: "edited"))
        let editedID = try XCTUnwrap(model.lastSessionCreationRequestID)
        XCTAssertNotEqual(originalID, editedID)

        await transport.emit(event(type: "session.created", messageID: originalID, sequence: 1,
                                   payload: .object([
                                    "id": .string("late-original"),
                                    "title": .string("Original"),
                                    "updatedAt": .number(1),
                                   ])))
        try await Task.sleep(for: .milliseconds(90))

        XCTAssertEqual(model.completedSessionCreationRequestID, originalID)
        XCTAssertNil(model.selectedSessionID,
                     "A late detached result must not navigate away from the newer draft")
        XCTAssertNil(model.sessionCreationFailure(for: originalID))
        XCTAssertEqual(model.lastSessionCreationRequestID, editedID)
        model.disconnect()
    }

    @MainActor
    func testSessionCreationRecoveryCanResumeAfterShortHttpWindow() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: DSHStoreState(), isPaired: true)
        model.sessionCreationAckTimeout = 0.01
        model.sessionCreationRetryWindow = 0.05
        model.connect()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(model.createSession(mode: "standard", initialPrompt: "unknown"))
        let requestID = try XCTUnwrap(model.lastSessionCreationRequestID)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertTrue(model.sessionCreationFailure(for: requestID)?.resultUnknown == true)
        let before = await transport.commandCount(ofType: "session.create")

        model.sessionCreationAckTimeout = 1
        model.retrySessionCreation(requestID: requestID)
        try await Task.sleep(for: .milliseconds(60))
        let after = await transport.commandCount(ofType: "session.create")
        XCTAssertEqual(after, before + 1,
                       "A durable create record must remain recoverable after the short HTTP cache window")
        XCTAssertNil(model.sessionCreationFailure(for: requestID))
        model.disconnect()
    }

    @MainActor
    func testSessionCreationTransactionRestoresAfterDisconnect() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: DSHStoreState(), isPaired: true)
        model.sessionCreationAckTimeout = 30
        model.connect()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(model.createSession(mode: "standard", initialPrompt: "restore me"))
        let requestID = try XCTUnwrap(model.lastSessionCreationRequestID)
        model.disconnect()
        XCTAssertNil(model.recoverableSessionCreationRequestID())

        model.connect()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.recoverableSessionCreationRequestID(), requestID)
        XCTAssertEqual(model.sessionCreationDraft(for: requestID)?.text, "restore me")
        model.disconnect()
    }

    @MainActor
    func testInitialMessageTransactionRestoresAfterDisconnect() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: DSHStoreState(), isPaired: true)
        model.sessionCreationAckTimeout = 1
        model.connect()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(model.createSession(mode: "standard", initialPrompt: "send after reconnect"))
        let createID = try XCTUnwrap(model.lastSessionCreationRequestID)
        await transport.emit(event(type: "session.created", messageID: createID, sequence: 1,
                                   payload: .object([
                                    "id": .string("session-first-message"),
                                    "title": .string("First message"),
                                    "updatedAt": .number(1),
                                   ])))
        try await Task.sleep(for: .milliseconds(80))
        let firstPromptValue = await transport.lastCommand(ofType: "prompt.send")
        let firstPrompt = try XCTUnwrap(firstPromptValue)
        model.disconnect()

        model.connect()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.failedInitialMessage(for: "session-first-message")?.text,
                       "send after reconnect")
        let failure = try XCTUnwrap(model.failedInitialMessage(for: "session-first-message"))
        model.retryFailedInitialMessage(failure)
        try await Task.sleep(for: .milliseconds(40))
        let retriedPromptValue = await transport.lastCommand(ofType: "prompt.send")
        let retriedPrompt = try XCTUnwrap(retriedPromptValue)
        XCTAssertEqual(retriedPrompt.requestId, firstPrompt.requestId,
                       "The first message retry must keep its prompt identity")
        if case .object(let payload) = retriedPrompt.payload {
            XCTAssertEqual(payload["text"], .string("send after reconnect"))
        } else {
            XCTFail("prompt.send payload was not an object")
        }
        model.disconnect()
    }

    @MainActor
    func testTwoSessionCreationResultsInOneEventBatchRemainRequestScoped() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: DSHStoreState(), isPaired: true)
        model.sessionCreationAckTimeout = 30
        model.connect()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(model.createSession(mode: "standard", initialPrompt: "one"))
        let firstID = try XCTUnwrap(model.lastSessionCreationRequestID)
        XCTAssertTrue(model.createSession(mode: "standard", initialPrompt: "two"))
        let secondID = try XCTUnwrap(model.lastSessionCreationRequestID)

        await transport.emit(event(type: "session.created", messageID: firstID, sequence: 1,
                                   payload: .object(["id": .string("session-one"), "title": .string("One"), "updatedAt": .number(1)])))
        await transport.emit(event(type: "session.created", messageID: secondID, sequence: 2,
                                   payload: .object(["id": .string("session-two"), "title": .string("Two"), "updatedAt": .number(2)])))
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.sessionCreationResults[firstID], "session-one")
        XCTAssertEqual(model.sessionCreationResults[secondID], "session-two")
        model.disconnect()
    }

    @MainActor
    func testSessionCreationRejectsModeFromAnotherMacCatalog() {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        var state = DSHStoreState()
        state.modeCatalog = DSHModeCatalog(defaultMode: "mac-b",
                                           modes: [DSHModeOption(id: "mac-b", name: "Mac B")])
        let model = makeModel(transport: DSHPreviewTransport(), initialState: state, isPaired: true)

        XCTAssertFalse(model.createSession(mode: "mac-a", initialPrompt: "stale"))
        XCTAssertEqual(model.errorMessage, "所选模式不属于当前 Mac，请重新选择。")
        XCTAssertTrue(model.createSession(mode: "mac-b", initialPrompt: "valid"))
        model.disconnect()
    }

    @MainActor
    func testPureAttachmentAcceptanceUsesRequestIdWhenMessageHasNoText() {
        let sid = "attachment-send-\(UUID().uuidString)"
        let requestID = "attachment-request-\(UUID().uuidString)"
        let model = makeModel(transport: DSHPreviewTransport(), initialState: DSHStoreState(), isPaired: true)
        model.sendPrompt("", attachments: ["receipt-1"], to: sid, requestId: requestID)
        XCTAssertEqual(model.pendingSendCount(for: sid), 1)

        // The accepted user message can contain only a file, so its markdown
        // is empty. The Bridge correlates the envelope message id to the
        // original prompt request and must still clear the pending bubble.
        model.confirmPendingSend(text: "", sessionID: sid, requestID: requestID)
        XCTAssertEqual(model.pendingSendCount(for: sid), 0)
        XCTAssertNil(model.failedSend)

        let lateRequestID = "late-attachment-request-\(UUID().uuidString)"
        model.sendPrompt("", attachments: ["receipt-2"], to: sid, requestId: lateRequestID)
        model.timeoutPendingSend(requestId: lateRequestID)
        XCTAssertNotNil(model.failedSend)
        model.confirmPendingSend(text: "", sessionID: sid, requestID: lateRequestID)
        XCTAssertNil(model.failedSend)
    }

    @MainActor
    func testOldPromptTimeoutCannotFailAReusedRequestId() async {
        let sid = "retry-timer-\(UUID().uuidString)"
        let requestID = "retry-\(UUID().uuidString)"
        let model = makeModel(transport: DSHPreviewTransport(), initialState: DSHStoreState(), isPaired: true)
        model.sendAckTimeout = 0.05
        model.sendPrompt("first", attachments: [], to: sid, requestId: requestID)
        try? await Task.sleep(nanoseconds: 20_000_000)
        model.sendPrompt("second", attachments: [], to: sid, requestId: requestID)

        // The first timer fires during the second attempt's acceptance window;
        // its generation must not remove the replacement pending send.
        // Leave enough margin for the first timer to fire, but keep the
        // replacement attempt inside its own acceptance window. Waiting
        // exactly one timeout here races the second timer on a busy runner.
        try? await Task.sleep(nanoseconds: 35_000_000)
        XCTAssertEqual(model.pendingSendCount(for: sid), 1)
        XCTAssertNil(model.failedSend)
        model.confirmPendingSend(text: "", sessionID: sid, requestID: requestID)
        XCTAssertEqual(model.pendingSendCount(for: sid), 0)
    }

    @MainActor
    func testLateFailureFromOlderPromptAttemptCannotOverwriteRetry() {
        let sid = "retry-error-\(UUID().uuidString)"
        let requestID = "retry-error-request-\(UUID().uuidString)"
        let model = makeModel(transport: DSHPreviewTransport(), initialState: DSHStoreState(), isPaired: true)
        model.sendPrompt("first", attachments: [], to: sid, requestId: requestID)
        let first = DSHCommand.sendPrompt(deviceId: "ios-device", machineId: "machine",
                                          sessionId: sid, text: "first", requestId: requestID)
        model.sendPrompt("second", attachments: [], to: sid, requestId: requestID)
        model.confirmPendingSend(text: "", sessionID: sid, requestID: requestID)
        model.parkFailedPromptSend(first, error: NSError(domain: "late", code: 1), attempt: 1)
        XCTAssertNil(model.failedSend)
    }

    @MainActor
    func testFailedPromptRetriesRemainScopedToTheirSession() {
        let firstSession = "failed-session-one-\(UUID().uuidString)"
        let secondSession = "failed-session-two-\(UUID().uuidString)"
        let firstRequest = "failed-request-one-\(UUID().uuidString)"
        let secondRequest = "failed-request-two-\(UUID().uuidString)"
        let model = makeModel(transport: DSHPreviewTransport(), initialState: DSHStoreState(), isPaired: true)

        model.sendPrompt("first", attachments: [], to: firstSession, requestId: firstRequest)
        model.sendPrompt("second", attachments: [], to: secondSession, requestId: secondRequest)
        model.timeoutPendingSend(requestId: firstRequest)
        model.timeoutPendingSend(requestId: secondRequest)

        XCTAssertEqual(model.failedSend(for: firstSession)?.id, firstRequest)
        XCTAssertEqual(model.failedSend(for: secondSession)?.id, secondRequest)
        model.dismissFailedSend(requestID: firstRequest)
        XCTAssertNil(model.failedSend(for: firstSession))
        XCTAssertEqual(model.failedSend(for: secondSession)?.id, secondRequest)
    }

    func testPromptAcceptanceReceiptDecodesAsRequestScopedEvent() {
        let event = DSHEvent(envelope: DSHEnvelope(
            messageId: "prompt-1", deviceId: "phone-1", machineId: "machine-1",
            sessionId: "session-1", sequence: 1, type: "prompt.accepted",
            payload: .object(["sessionId": .string("session-1"), "requestId": .string("prompt-1")])
        ))
        guard case .promptAccepted(let receipt) = event.kind else {
            return XCTFail("prompt.accepted should decode as a request receipt")
        }
        XCTAssertEqual(receipt.sessionId, "session-1")
        XCTAssertEqual(receipt.requestId, "prompt-1")
    }


    func testTaskTimelineCombinesStepsWithoutMovingMessagesOrCommands() {
        let messages = [
            DSHChatMessage(id: "u", role: .user, markdown: "task", sequence: 1, timestamp: 1_000),
            DSHChatMessage(id: "a", role: .assistant, markdown: "progress", reasoning: "first", sequence: 2),
            DSHChatMessage(id: "b", role: .assistant, markdown: "more", reasoning: "second", sequence: 4),
            DSHChatMessage(id: "c", role: .assistant, markdown: "done", sequence: 6),
            DSHChatMessage(id: "u2", role: .user, markdown: "next", sequence: 7),
            DSHChatMessage(id: "d", role: .assistant, markdown: "next answer", sequence: 8),
        ]
        let sections = messages.transcriptEntries(with: [
            DSHToolActivity(id: "t", name: "bash", status: "succeeded", sequence: 3)
        ], commandResults: [DSHCommandResult(sessionId: "s", requestId: "cmd", matched: true, sequence: 5)])
            .groupedTurns()
        let annotated = sections.withTaskTimelines()
        XCTAssertEqual(annotated.map(\.id), sections.map(\.id))
        let headers = annotated.compactMap { section -> DSHTaskTimeline? in
            if case .turn(let block, _) = section { return block.taskTimeline }
            return nil
        }
        XCTAssertEqual(headers.count, 2)
        XCTAssertEqual(headers[0].promptID, "u")
        XCTAssertEqual(headers[0].messages.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(headers[0].reasoning, "first\n\nsecond")
        XCTAssertEqual(headers[0].tools.map(\.id), ["t"])
        XCTAssertEqual(headers[1].messages.map(\.id), ["d"])
    }

    func testTaskDurationUsesWallClockAndMarksHistoricalEstimate() throws {
        var a = DSHChatMessage(id: "a", role: .assistant, markdown: "first")
        a.completedAt = 3_000
        var b = DSHChatMessage(id: "b", role: .assistant, markdown: "done")
        b.completedAt = 8_000
        b.taskCompletedAt = 12_000 // Includes the final tool execution.
        let live = DSHTaskTimeline(promptID: "u", startedAt: 1_000, messages: [a, b], tools: [])
        XCTAssertEqual(live.duration()?.seconds, 11)
        XCTAssertEqual(live.duration()?.estimated, false)
        XCTAssertEqual(live.duration(now: Date(timeIntervalSince1970: 20))?.seconds, 19)
        a.completedAt = nil
        b.completedAt = nil
        b.taskCompletedAt = nil
        a.usage = DSHSessionUsage(inputTokens: 99_999, outputTokens: 20, tokensPerSecond: 10)
        b.usage = DSHSessionUsage(inputTokens: 99_999, outputTokens: 70, tokensPerSecond: 10)
        let history = DSHTaskTimeline(promptID: "u", startedAt: 1_000, messages: [a, b], tools: [])
        XCTAssertEqual(history.duration()?.seconds, 9)
        XCTAssertEqual(history.duration()?.estimated, true)
        XCTAssertNil(DSHTaskTimeline(promptID: nil, startedAt: nil, messages: [], tools: []).duration())
    }

    func testTaskCompletionTimeSurvivesReplayAndOldPayloadDecoding() throws {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        var sequence: Int64 = 0
        func emit(_ type: String, _ payload: DSHJSONValue, at timestamp: Int64, history: Bool = false) {
            sequence += 1
            reducer.reduce(DSHEvent(envelope: DSHEnvelope(messageId: "evt-\(sequence)", deviceId: "d",
                machineId: "m", sessionId: "s", historyBatchId: history ? "history" : nil,
                sequence: sequence, timestamp: timestamp, type: type, payload: payload)), into: &state)
        }
        let answer: DSHJSONValue = .object(["id": .string("a"), "role": .string("assistant"), "markdown": .string("done")])
        emit("user.message.accepted", .object(["id": .string("u"), "role": .string("user"), "markdown": .string("go")]), at: 1_000)
        emit("turn.state.changed", .object(["sessionId": .string("s"), "state": .string("running")]), at: 1_001)
        emit("assistant.message.delta", .object(["messageId": .string("a"), "text": .string("d")]), at: 2_000)
        emit("assistant.message.completed", answer, at: 5_000)
        emit("turn.state.changed", .object(["sessionId": .string("s"), "state": .string("idle")]), at: 9_000)
        emit("assistant.message.completed", answer, at: 100_000, history: true)
        let completed = try XCTUnwrap(state.messagesBySession["s"]?.last)
        XCTAssertEqual(completed.timestamp, 2_000)
        XCTAssertEqual(completed.completedAt, 5_000)
        XCTAssertEqual(completed.taskCompletedAt, 9_000)
        let decoded = try JSONDecoder().decode(DSHChatMessage.self, from: JSONEncoder().encode(completed))
        XCTAssertEqual(decoded.taskCompletedAt, 9_000)
        let legacy = try JSONDecoder().decode(DSHChatMessage.self, from: Data(#"{"id":"old","role":"assistant","markdown":"done"}"#.utf8))
        XCTAssertNil(legacy.completedAt)
        emit("assistant.message.completed", .object(["id": .string("old"), "role": .string("assistant"), "markdown": .string("old")]), at: 200_000, history: true)
        XCTAssertNil(state.messagesBySession["s"]?.last?.completedAt)
    }

    func testToolsFoldIntoPrecedingAssistantTurn() {
        let entries: [DSHTranscriptEntry] = [
            .turn(DSHTranscriptBlock(id: "q", messages: [
                DSHChatMessage(id: "q", role: .user, markdown: "q?", sequence: 1),
            ])),
            .turn(DSHTranscriptBlock(id: "a1", messages: [
                DSHChatMessage(id: "a1", role: .assistant, markdown: "ans", sequence: 2),
            ])),
            .tool(DSHToolActivity(id: "t", name: "bash", status: "succeeded", sequence: 3)),
        ]
        let sections = entries.groupedTurns()
        XCTAssertEqual(sections.count, 2)
        guard case .turn(let block, let tools) = sections[1] else {
            return XCTFail("Assistant turn should carry its tools")
        }
        XCTAssertEqual(block.id, "a1")
        XCTAssertEqual(tools.map(\.id), ["t"])
    }

    func testOrphanToolWithoutAssistantTurnStaysStandalone() {
        let entries: [DSHTranscriptEntry] = [
            .tool(DSHToolActivity(id: "t", name: "bash", status: "running", sequence: 1)),
            .turn(DSHTranscriptBlock(id: "q", messages: [
                DSHChatMessage(id: "q", role: .user, markdown: "q?", sequence: 2),
            ])),
        ]
        let sections = entries.groupedTurns()
        XCTAssertEqual(sections.count, 2)
        guard case .row(let entry) = sections[0] else {
            return XCTFail("Orphan tool should stand alone")
        }
        XCTAssertEqual(entry.id, "tool-t")
    }

    func testReasoningOnlyTurnsFoldIntoFollowingAnswer() {
        // One agentic turn arrives as think → tool → think → tool → answer.
        // Rendering one "思考" row per think step buries the conversation;
        // they must fold into a single timeline row with the final answer.
        let entries: [DSHTranscriptEntry] = [
            .turn(DSHTranscriptBlock(id: "r1", messages: [
                DSHChatMessage(id: "r1", role: .assistant, markdown: "",
                               reasoning: "first thought", sequence: 1),
            ])),
            .tool(DSHToolActivity(id: "t1", name: "bash", status: "succeeded", sequence: 2)),
            .turn(DSHTranscriptBlock(id: "r2", messages: [
                DSHChatMessage(id: "r2", role: .assistant, markdown: "",
                               reasoning: "second thought", sequence: 3),
            ])),
            .tool(DSHToolActivity(id: "t2", name: "bash", status: "succeeded", sequence: 4)),
            .turn(DSHTranscriptBlock(id: "a", messages: [
                DSHChatMessage(id: "a", role: .assistant, markdown: "done", sequence: 5),
            ])),
        ]
        let sections = entries.groupedTurns()
        XCTAssertEqual(sections.count, 1)
        guard case .turn(let block, let tools) = sections[0] else {
            return XCTFail("Think steps should fold into the answer turn")
        }
        XCTAssertEqual(block.messages.map(\.id), ["r1", "r2", "a"])
        XCTAssertEqual(block.visibleMessages.map(\.id), ["a"])
        XCTAssertTrue(block.reasoning.contains("first thought"))
        XCTAssertTrue(block.reasoning.contains("second thought"))
        XCTAssertEqual(tools.map(\.id), ["t1", "t2"])
    }

    func testNewUserTaskDoesNotInheritPreviousReasoning() {
        // A new prompt closes the previous task, even if it only reasoned.
        let entries: [DSHTranscriptEntry] = [
            .turn(DSHTranscriptBlock(id: "r", messages: [
                DSHChatMessage(id: "r", role: .assistant, markdown: "",
                               reasoning: "thinking…", sequence: 1),
            ])),
            .turn(DSHTranscriptBlock(id: "u", messages: [
                DSHChatMessage(id: "u", role: .user, markdown: "and?", sequence: 2),
            ])),
            .command(DSHCommandResult(sessionId: "s", requestId: "c1", matched: true,
                                      kind: "goal", text: "goal set", sequence: 3)),
            .turn(DSHTranscriptBlock(id: "a", messages: [
                DSHChatMessage(id: "a", role: .assistant, markdown: "done", sequence: 4),
            ])),
        ]
        let sections = entries.groupedTurns()
        XCTAssertEqual(sections.count, 4)
        guard case .turn(let block, _) = sections[3] else {
            return XCTFail("Think step should fold into the answer turn")
        }
        XCTAssertEqual(block.messages.map(\.id), ["a"])
        XCTAssertEqual(block.visibleMessages.map(\.id), ["a"])
    }

    func testTrailingReasoningOnlyTurnStaysStandalone() {
        // Live streaming: reasoning arrived but the answer text has not yet.
        // It must stay visible (with its running tools) rather than vanish.
        let entries: [DSHTranscriptEntry] = [
            .turn(DSHTranscriptBlock(id: "a", messages: [
                DSHChatMessage(id: "a", role: .assistant, markdown: "done", sequence: 1),
            ])),
            .turn(DSHTranscriptBlock(id: "r", messages: [
                DSHChatMessage(id: "r", role: .assistant, markdown: "",
                               reasoning: "thinking…", sequence: 2),
            ])),
            .tool(DSHToolActivity(id: "t", name: "bash", status: "running", sequence: 3)),
        ]
        let sections = entries.groupedTurns()
        XCTAssertEqual(sections.count, 2)
        guard case .turn(let block, let tools) = sections[1] else {
            return XCTFail("Live think step should stay its own section")
        }
        XCTAssertEqual(block.messages.map(\.id), ["r"])
        XCTAssertEqual(tools.map(\.id), ["t"])
    }

    func testModelChangeDoesNotSplitReasoningFold() {
        // think → model notice → answer must render one timeline row, not a
        // stranded "思考" row above the duration row.
        let notice = DSHModelChangeNotice(
            sessionId: "s",
            current: DSHModelSelection(provider: "p", model: "m"),
            sequence: 2, timestamp: 2)
        let entries: [DSHTranscriptEntry] = [
            .turn(DSHTranscriptBlock(id: "r", messages: [
                DSHChatMessage(id: "r", role: .assistant, markdown: "",
                               reasoning: "thinking…", sequence: 1),
            ])),
            .modelChange(notice),
            .turn(DSHTranscriptBlock(id: "a", messages: [
                DSHChatMessage(id: "a", role: .assistant, markdown: "done", sequence: 3),
            ])),
        ]
        let sections = entries.groupedTurns()
        XCTAssertEqual(sections.count, 2)
        guard case .turn(let block, _) = sections[1] else {
            return XCTFail("Think step should fold into the answer turn")
        }
        XCTAssertEqual(block.messages.map(\.id), ["r", "a"])
        XCTAssertEqual(block.visibleMessages.map(\.id), ["a"])
    }

    func testReplayedRowsKeepFirstSequenceInsteadOfRenumbering() {        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        // Live rows first.
        reducer.reduce(userMessageEvent(id: "q", text: "q?", sequence: 1), into: &state)
        reducer.reduce(toolStartedEvent(id: "t", sequence: 2), into: &state)
        // The same rows replayed later (re-open, refresh, backfill) update
        // content in place but must not move ahead of live rows that
        // followed the first sighting.
        reducer.reduce(userMessageEvent(id: "q", text: "q?", sequence: 10), into: &state)
        reducer.reduce(toolStartedEvent(id: "t", sequence: 11), into: &state)

        XCTAssertEqual(state.messagesBySession["s"]?.first?.sequence, 1)
        XCTAssertEqual(state.toolsBySession["s"]?.first?.sequence, 2)

        let messages = state.messagesBySession["s"] ?? []
        let tools = state.toolsBySession["s"] ?? []
        let entries = messages.transcriptEntries(with: tools)
        XCTAssertEqual(entries.map(\.id), ["turn-q", "tool-t"])
    }

    func testMessageTimestampIsStampedOnceAndSurvivesReplay() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        func accepted(sequence: Int64, timestamp: Int64) -> DSHEvent {
            DSHEvent(envelope: DSHEnvelope(
                messageId: "evt-\(sequence)", deviceId: "d", machineId: "m",
                sessionId: "s", sequence: sequence, timestamp: timestamp,
                type: "user.message.accepted",
                payload: .object([
                    "id": .string("q"),
                    "role": .string("user"),
                    "markdown": .string("q?"),
                ])
            ))
        }
        reducer.reduce(accepted(sequence: 1, timestamp: 1_000), into: &state)
        reducer.reduce(accepted(sequence: 10, timestamp: 2_000), into: &state)
        XCTAssertEqual(state.messagesBySession["s"]?.first?.timestamp, 1_000)
    }

    func testReplayWithoutAttachmentMetadataRetainsLocalMessageAttachments() {
        var state = DSHStoreState()
        let reducer = DSHEventReducer()
        let attachment = DSHMessageAttachment(id: "receipt-1", name: "photo.jpg",
                                               mediaType: "image/jpeg", receiptId: "receipt-1")
        let live = DSHEvent(envelope: DSHEnvelope(
            messageId: "live", deviceId: "d", machineId: "m", sessionId: "s",
            sequence: 1, type: "user.message.accepted",
            payload: .object([
                "id": .string("message-1"), "role": .string("user"),
                "markdown": .string("look"),
                "attachments": .array([.object([
                    "id": .string("receipt-1"), "name": .string("photo.jpg"),
                    "mediaType": .string("image/jpeg"), "receiptId": .string("receipt-1")
                ])])
            ])))
        reducer.reduce(live, into: &state)

        let replay = DSHEvent(envelope: DSHEnvelope(
            messageId: "replay", deviceId: "d", machineId: "m", sessionId: "s",
            historyBatchId: "history-1", sequence: 2, type: "user.message.accepted",
            payload: .object([
                "id": .string("message-1"), "role": .string("user"),
                "markdown": .string("look")
            ])))
        reducer.reduce(replay, into: &state)
        XCTAssertEqual(state.messagesBySession["s"]?.first?.attachments, [attachment])
    }

    func testHistoricalTurnStateDoesNotOverrideLiveProjection() {
        var state = DSHStoreState()
        state.turnStateBySession["s"] = "running"
        let historical = DSHEvent(envelope: DSHEnvelope(
            messageId: "history-turn", deviceId: "d", machineId: "m", sessionId: "s",
            historyBatchId: "history-1", sequence: 1, type: "turn.state.changed",
            payload: .object(["sessionId": .string("s"), "state": .string("completed")])
        ))
        DSHEventReducer().reduce(historical, into: &state)
        XCTAssertEqual(state.turnStateBySession["s"], "running")

        let live = DSHEvent(envelope: DSHEnvelope(
            messageId: "live-turn", deviceId: "d", machineId: "m", sessionId: "s",
            sequence: 2, type: "turn.state.changed",
            payload: .object(["sessionId": .string("s"), "state": .string("completed")])
        ))
        DSHEventReducer().reduce(live, into: &state)
        XCTAssertEqual(state.turnStateBySession["s"], "completed")
    }

    func testFreshSessionSnapshotReconcilesRunningStateAfterOpeningOrReconnect() {
        var state = DSHStoreState()
        state.turnStateBySession = ["settled": "running", "failed": "failed", "unknown": "running"]
        let snapshot = DSHEvent(envelope: DSHEnvelope(
            messageId: "snapshot", deviceId: "d", machineId: "m", sequence: 1,
            type: "session.snapshot", payload: .array([
                .object(["id": .string("active"), "title": .string("Active"),
                         "updatedAt": .number(1), "running": .bool(true)]),
                .object(["id": .string("settled"), "title": .string("Settled"),
                         "updatedAt": .number(1), "running": .bool(false)]),
                .object(["id": .string("failed"), "title": .string("Failed"),
                         "updatedAt": .number(1), "running": .bool(false)]),
                .object(["id": .string("unknown"), "title": .string("Legacy"),
                         "updatedAt": .number(1)]),
            ])
        ))
        DSHEventReducer().reduce(snapshot, into: &state)
        XCTAssertEqual(state.turnStateBySession["active"], "running")
        XCTAssertEqual(state.turnStateBySession["settled"], "idle")
        XCTAssertEqual(state.turnStateBySession["failed"], "failed")
        XCTAssertEqual(state.turnStateBySession["unknown"], "running")
    }

    @MainActor
    func testSessionDotPrioritizesErrorOverApprovalOverActivity() {
        var state = DSHStoreState()
        let quiet = DSHSessionSummary(id: "quiet", title: "q", updatedAt: 0)
        let failed = DSHSessionSummary(id: "failed", title: "f", updatedAt: 0)
        let waiting = DSHSessionSummary(id: "waiting", title: "w", updatedAt: 0)
        let active = DSHSessionSummary(id: "active", title: "a", updatedAt: 0, running: true)
        state.sessions = [quiet, failed, waiting, active]
        state.turnStateBySession["failed"] = "failed"
        state.pendingApprovals = [
            DSHApprovalRequest(id: "ap", sessionId: "waiting", toolName: "bash", reason: "run?"),
        ]
        let model = makeModel(transport: DSHPreviewTransport(), initialState: state, isPaired: true)
        XCTAssertEqual(model.sessionDot(for: quiet), .none)
        XCTAssertEqual(model.sessionDot(for: failed), .red)
        XCTAssertEqual(model.sessionDot(for: waiting), .yellow)
        XCTAssertEqual(model.sessionDot(for: active), .green)
    }

    @MainActor
    func testLocalTransportFailureClearsWorkspaceAndDirectoryLoading() async {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport(failingTypes: ["workspace.create", "directory.list"])
        let model = makeModel(transport: transport, initialState: .init(), isPaired: true)

        model.createWorkspace(at: "/Users/me/Project")
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(model.isCreatingWorkspace)

        model.listDirectory(at: "/Users/me")
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(model.isLoadingDirectory)
    }

    @MainActor
    func testReplayGapNoticeCoalescesIntoOneSilentReadOnlyResynchronization() async {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: .init(), isPaired: true)
        model.connect()
        try? await Task.sleep(for: .milliseconds(30))
        model.setConversationVisible("active-session", visible: true)
        model.openSession("active-session")
        try? await Task.sleep(for: .milliseconds(30))

        await transport.emit(event(type: "transport.state", messageID: "connected", sequence: 0,
                                   payload: .object(["state": .string("connected")])))
        await transport.emit(event(type: "machine.presence", messageID: "presence", sequence: 0,
                                   payload: .bool(true)))
        // Connector can emit both notices from the same buffered reconnect.
        await transport.emit(event(type: "protocol.error", messageID: "gap-1", sequence: 1,
                                   payload: .object([
                                    "code": .string("replay-window-exceeded"),
                                    "message": .string("Some offline events expired; reopen the session to resynchronize."),
                                    "retryable": .bool(true),
                                   ])))
        await transport.emit(event(type: "protocol.error", messageID: "gap-2", sequence: 2,
                                   payload: .object([
                                    "code": .string("offline-queue-exceeded"),
                                    "message": .string("Some offline events expired; reopen active sessions to resynchronize."),
                                    "retryable": .bool(true),
                                   ])))
        try? await Task.sleep(for: .milliseconds(140))

        XCTAssertNil(model.errorMessage)
        let sessionLists = await transport.commandCount(ofType: "session.list")
        let workspaceCatalogs = await transport.commandCount(ofType: "workspace.catalog")
        let modeCatalogs = await transport.commandCount(ofType: "mode.catalog")
        let modelCatalogs = await transport.commandCount(ofType: "model.catalog")
        let sessionOpens = await transport.commandCount(ofType: "session.open")
        XCTAssertEqual(sessionLists, 1)
        XCTAssertEqual(workspaceCatalogs, 1,
                       "Handshake and replay recovery must not duplicate the catalog batch")
        XCTAssertEqual(modeCatalogs, 1)
        XCTAssertEqual(modelCatalogs, 1)
        XCTAssertEqual(sessionOpens, 2,
                       "The visible transcript is read once normally and once to resynchronize")
        model.disconnect()
    }

    @MainActor
    func testReadOnlyNotConnectedWaitsForNewReadinessWithoutRetryLoop() async {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        var state = DSHStoreState()
        // Model state can briefly remain connected while URLSession has
        // already dropped its task. The coordinator must wait for a new
        // readiness control event instead of Task.yield retrying forever.
        state.transportState = .connected
        state.connectionState = .connected
        state.machineOnline = true
        let transport = CorrelationTransport(failFirstTypes: ["session.open"])
        let model = makeModel(transport: transport, initialState: state, isPaired: true)
        model.connect()
        try? await Task.sleep(for: .milliseconds(30))
        await transport.emit(event(type: "transport.state", messageID: "initial-ready", sequence: 0,
                                   payload: .object(["state": .string("connected")])))
        await transport.emit(event(type: "machine.presence", messageID: "initial-presence", sequence: 0,
                                   payload: .bool(true)))
        try? await Task.sleep(for: .milliseconds(80))

        model.openSession("pending-session")
        try? await Task.sleep(for: .milliseconds(100))
        let beforeNewReadiness = await transport.commandCount(ofType: "session.open")
        XCTAssertEqual(beforeNewReadiness, 1)
        XCTAssertNil(model.errorMessage)

        await transport.emit(event(type: "transport.state", messageID: "fresh-ready", sequence: 0,
                                   payload: .object(["state": .string("connected")])))
        await transport.emit(event(type: "machine.presence", messageID: "fresh-presence", sequence: 0,
                                   payload: .bool(true)))
        try? await Task.sleep(for: .milliseconds(100))
        let afterNewReadiness = await transport.commandCount(ofType: "session.open")
        XCTAssertEqual(afterNewReadiness, 2)
        XCTAssertNil(model.errorMessage)
        model.disconnect()
    }

    @MainActor
    func testReplayRecoveryDoesNotReopenConversationAfterExitOrConnectionReset() async {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: .init(), isPaired: true)
        model.connect()
        try? await Task.sleep(for: .milliseconds(40))
        model.setConversationVisible("no-longer-visible", visible: true)
        await transport.emit(event(type: "protocol.error", messageID: "pending-gap", sequence: 1,
                                   payload: .object([
                                    "code": .string("replay-window-exceeded"),
                                    "message": .string("Some offline events expired."),
                                    "retryable": .bool(true),
                                   ])))
        try? await Task.sleep(for: .milliseconds(80))
        model.setConversationVisible("no-longer-visible", visible: false)
        model.disconnect()
        try? await Task.sleep(for: .milliseconds(100))

        model.connect()
        try? await Task.sleep(for: .milliseconds(60))
        await transport.emit(event(type: "transport.state", messageID: "ready-after-reset", sequence: 0,
                                   payload: .object(["state": .string("connected")])))
        await transport.emit(event(type: "machine.presence", messageID: "presence-after-reset", sequence: 0,
                                   payload: .bool(true)))
        try? await Task.sleep(for: .milliseconds(100))
        let reopenedSessions = await transport.commandCount(ofType: "session.open")
        let replayLists = await transport.commandCount(ofType: "session.list")
        XCTAssertEqual(reopenedSessions, 0)
        XCTAssertEqual(replayLists, 0,
                       "A reset drops stale replay recovery instead of using it on the new socket")
        XCTAssertNil(model.errorMessage)
        model.disconnect()
    }

    @MainActor
    func testOrdinaryProtocolErrorStillSurfacesToTheUser() async {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: .init(), isPaired: true)
        model.connect()
        try? await Task.sleep(for: .milliseconds(30))
        await transport.emit(event(type: "protocol.error", messageID: "real-error", sequence: 1,
                                   payload: .object([
                                    "code": .string("permission-denied"),
                                    "message": .string("Permission was denied."),
                                    "retryable": .bool(false),
                                   ])))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.errorMessage, "Permission was denied.")
        model.disconnect()
    }

    @MainActor
    func testWorkspaceCreationDismissesOnlyForMatchingRemoteAcknowledgement() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: .init(), isPaired: true)
        model.connect()
        model.createWorkspace(at: "/Users/me/Existing")
        try? await Task.sleep(for: .milliseconds(80))
        let pendingCommand = await transport.lastCommand(ofType: "workspace.create")
        let requestID = try XCTUnwrap(pendingCommand?.requestId)

        await transport.emit(event(type: "workspace.created", messageID: "another-device", sequence: 1,
                                   payload: .object([
                                    "id": .string("existing"), "path": .string("/Users/me/Existing"),
                                    "title": .string("Existing"),
                                   ])))
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(model.isCreatingWorkspace)
        XCTAssertNil(model.createdWorkspace)

        await transport.emit(event(type: "workspace.created", messageID: requestID, sequence: 2,
                                   payload: .object([
                                    "id": .string("existing"), "path": .string("/Users/me/Existing"),
                                    "title": .string("Existing"),
                                   ])))
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(model.isCreatingWorkspace)
        XCTAssertEqual(model.createdWorkspace?.id, "existing")
        XCTAssertEqual(model.createdWorkspace?.name, "Existing")
        model.disconnect()
    }

    @MainActor
    func testOnlyLatestDirectoryReplyUpdatesFolderBrowser() async throws {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: .init(), isPaired: true)
        model.connect()
        model.listDirectory(at: "/Users/me")
        try? await Task.sleep(for: .milliseconds(50))
        let firstCommand = await transport.lastCommand(ofType: "directory.list")
        let firstID = try XCTUnwrap(firstCommand?.requestId)
        model.listDirectory(at: "/Users/me/New")
        try? await Task.sleep(for: .milliseconds(50))
        let secondCommand = await transport.lastCommand(ofType: "directory.list")
        let secondID = try XCTUnwrap(secondCommand?.requestId)
        XCTAssertNotEqual(firstID, secondID)

        await transport.emit(event(type: "directory.list", messageID: firstID, sequence: 1,
                                   payload: directoryPayload(path: "/Users/me", directory: "Old")))
        await transport.emit(event(type: "directory.list", messageID: secondID, sequence: 2,
                                   payload: directoryPayload(path: "/Users/me/New", directory: "Current")))
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.directoryListing?.path, "/Users/me/New")
        XCTAssertEqual(model.directoryListing?.directories.map(\.name), ["Current"])
        XCTAssertFalse(model.isLoadingDirectory)
        model.disconnect()
    }

    @MainActor
    func testTranscriptCacheRefreshesForLiveDeltaAndLocalHide() async {
        let restoreProfile = installCorrelationTestProfile()
        defer { restoreProfile() }
        UserDefaults.standard.removeObject(forKey: DSHAppModel.hiddenMessagesKey)
        defer { UserDefaults.standard.removeObject(forKey: DSHAppModel.hiddenMessagesKey) }

        var state = DSHStoreState()
        state.messagesBySession["s"] = [
            DSHChatMessage(id: "question", role: .user, markdown: "Hello", sequence: 1),
        ]
        let transport = CorrelationTransport()
        let model = makeModel(transport: transport, initialState: state, isPaired: true)

        // Prime both caches before the live event arrives.
        XCTAssertEqual(model.transcriptEntries(for: "s").map(\.id), ["turn-question"])
        XCTAssertEqual(model.transcriptSections(for: "s").map(\.id), ["section-turn-question"])

        model.connect()
        try? await Task.sleep(for: .milliseconds(30))
        await transport.emit(DSHEvent(envelope: DSHEnvelope(
            messageId: "delta", deviceId: "device", machineId: "machine", sessionId: "s",
            sequence: 2, type: "assistant.message.delta",
            payload: .object(["messageId": .string("partial"), "text": .string("Live")])
        )))
        try? await Task.sleep(for: .milliseconds(90))

        XCTAssertEqual(model.transcriptEntries(for: "s").map(\.id), ["turn-question", "turn-partial"])
        model.hideMessage("partial", in: "s")
        XCTAssertEqual(model.transcriptEntries(for: "s").map(\.id), ["turn-question"])
        model.disconnect()
    }

    private func directoryPayload(path: String, directory: String) -> DSHJSONValue {
        .object([
            "path": .string(path),
            "directories": .array([
                .object(["name": .string(directory), "path": .string("\(path)/\(directory)")]),
            ]),
        ])
    }

    /// DSHAppModel deliberately reconciles pairing/profile state while its
    /// pending transaction ledger loads. These transport tests need a real
    /// matching active profile so that guard is exercised instead of bypassed.
    @MainActor
    private func makeModel(transport: any DSHAppTransport, initialState: DSHStoreState = .init(),
                           isPaired: Bool? = nil, transactionDirectory: URL? = nil) -> DSHAppModel {
        DSHAppModel(transport: transport, initialState: initialState, isPaired: isPaired,
            transactionDirectory: transactionDirectory ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("DSHStoreTests-\(UUID().uuidString)", isDirectory: true))
    }

    private func installCorrelationTestProfile() -> () -> Void {
        let defaults = UserDefaults.standard
        let previousProfiles = defaults.object(forKey: DSHProfileStore.profilesKey)
        let previousActiveMachine = defaults.object(forKey: DSHProfileStore.activeMachineKey)
        let profile = DSHRemoteProfile(relayBaseURL: URL(string: "https://example.test")!,
                                       deviceId: "test-device", machineId: "machine",
                                       machineName: "Test Mac")
        defaults.set(try! JSONEncoder().encode([profile]), forKey: DSHProfileStore.profilesKey)
        defaults.set(profile.machineId, forKey: DSHProfileStore.activeMachineKey)
        return {
            if let previousProfiles {
                defaults.set(previousProfiles, forKey: DSHProfileStore.profilesKey)
            } else {
                defaults.removeObject(forKey: DSHProfileStore.profilesKey)
            }
            if let previousActiveMachine {
                defaults.set(previousActiveMachine, forKey: DSHProfileStore.activeMachineKey)
            } else {
                defaults.removeObject(forKey: DSHProfileStore.activeMachineKey)
            }
        }
    }

    private func event(type: String, messageID: String, sequence: Int64,
                       payload: DSHJSONValue) -> DSHEvent {
        DSHEvent(envelope: DSHEnvelope(messageId: messageID, deviceId: "device", machineId: "machine",
                                        sequence: sequence, type: type, payload: payload))
    }
}

private actor CorrelationTransport: DSHAppTransport {
    private var continuation: AsyncThrowingStream<DSHEvent, Error>.Continuation?
    private var commands: [DSHCommand] = []
    private let failingTypes: Set<String>
    private var failFirstTypes: Set<String>
    private var upgradeRejectedTypes: Set<String>

    init(failingTypes: Set<String> = [], failFirstTypes: Set<String> = [], upgradeRejectedTypes: Set<String> = []) {
        self.failingTypes = failingTypes
        self.failFirstTypes = failFirstTypes
        self.upgradeRejectedTypes = upgradeRejectedTypes
    }

    func pair(serverAddress: String, machineId: String, credential: DSHPairingCredential,
              deviceName: String) async throws -> DSHRemoteProfile {
        DSHRemoteProfile(relayBaseURL: URL(string: "https://example.test")!,
                         deviceId: "device", machineId: "machine", machineName: "Mac")
    }

    func connect() async -> AsyncThrowingStream<DSHEvent, Error> {
        let stream = AsyncThrowingStream<DSHEvent, Error>.makeStream()
        continuation = stream.continuation
        return stream.stream
    }

    func setIncludeArchived(_ value: Bool) async {}

    func send(_ command: DSHCommand) async throws {
        commands.append(command)
        if upgradeRejectedTypes.remove(command.type) != nil { throw DSHRelayFeatureUpgradeRequired() }
        if failingTypes.contains(command.type) {
            throw DSHWebSocketError.notConnected
        }
        if failFirstTypes.remove(command.type) != nil {
            throw DSHWebSocketError.notConnected
        }
    }

    func disconnect() async { continuation?.finish(); continuation = nil }
    func forgetPairing() async throws { await disconnect() }
    func setActiveMachine(_ machineId: String) async {}
    func removeMachine(_ machineId: String) async throws {}
    func pairedDevices() async throws -> [DSHRelayDevice] { [] }
    func revokeDevice(_ deviceId: String) async throws {}

    func lastCommand(ofType type: String) -> DSHCommand? {
        commands.last(where: { $0.type == type })
    }

    func commandCount(ofType type: String) -> Int {
        commands.filter { $0.type == type }.count
    }

    func emit(_ event: DSHEvent) { continuation?.yield(event) }
}

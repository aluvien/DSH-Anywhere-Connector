import XCTest
@testable import DSHAnywhere

final class DSHHistoryCacheTests: XCTestCase {
    func testRoundTripIsScopedAndRestoresOnlyReadOnlyTranscriptState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = DSHHistoryCache(directory: directory)
        var state = fixtureState()
        state.turnStateBySession["session"] = "running"
        state.liveGoalSessions = ["session"]
        state.pendingApprovals = [.init(id: "approval", sessionId: "session", toolName: "bash", reason: "test")]
        let record = DSHHistoryCacheRecord(state: state, session: "session", fingerprint: "native-history-v1")
        try await cache.save(record, scope: "mac-a")

        let otherMachine = await cache.load(scope: "mac-b", session: "session")
        XCTAssertNil(otherMachine)
        let cachedRecord = await cache.load(scope: "mac-a", session: "session")
        let loaded = try XCTUnwrap(cachedRecord)
        XCTAssertEqual(loaded.fingerprint, "native-history-v1")
        var restored = DSHStoreState()
        loaded.restore(into: &restored)

        XCTAssertEqual(restored.messagesBySession["session"]?.map(\.markdown), ["cached"])
        XCTAssertEqual(restored.toolsBySession["session"]?.first?.status, "unknown")
        XCTAssertNil(restored.turnStateBySession["session"])
        XCTAssertFalse(restored.liveGoalSessions?.contains("session") == true)
        XCTAssertTrue(restored.pendingApprovals.isEmpty)
        XCTAssertEqual(restored.sessions.first?.running, false)
        XCTAssertEqual(restored.historyCoverage?["session"]?.throughSeq, 10)
    }

    func testCorruptRecordIsANonFatalCacheMiss() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = DSHHistoryCache(directory: directory)
        try await cache.save(DSHHistoryCacheRecord(state: fixtureState(), sessionID: "session"), scope: "mac-a")
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("history-cache"), includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first)
        try Data("not-json".utf8).write(to: file)
        let recovered = await cache.load(scope: "mac-a", session: "session")
        XCTAssertNil(recovered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSummariesAndRemovalStayWithinMachineScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = DSHHistoryCache(directory: directory)
        try await cache.save(DSHHistoryCacheRecord(state: fixtureState(session: "one", updatedAt: 2), sessionID: "one"), scope: "mac-a")
        try await cache.save(DSHHistoryCacheRecord(state: fixtureState(session: "two", updatedAt: 3), sessionID: "two"), scope: "mac-a")
        try await cache.save(DSHHistoryCacheRecord(state: fixtureState(session: "other", updatedAt: 4), sessionID: "other"), scope: "mac-b")
        let firstMachineSummaries = await cache.summaries(scope: "mac-a")
        XCTAssertEqual(firstMachineSummaries.map(\.id), ["two", "one"])
        try await cache.remove(scope: "mac-a")
        let removedMachineSummaries = await cache.summaries(scope: "mac-a")
        XCTAssertTrue(removedMachineSummaries.isEmpty)
        let secondMachineSummaries = await cache.summaries(scope: "mac-b")
        XCTAssertEqual(secondMachineSummaries.map(\.id), ["other"])
    }

    private func fixtureState(session: String = "session", updatedAt: Int64 = 1) -> DSHStoreState {
        var state = DSHStoreState()
        state.sessions = [.init(id: session, title: "Cached", updatedAt: updatedAt, running: true)]
        state.messagesBySession[session] = [.init(id: "message", role: .assistant, markdown: "cached", nativeSequence: 10)]
        state.toolsBySession[session] = [.init(id: "tool", name: "bash", status: "running")]
        state.historyCoverage = [session: .init(throughSeq: 10, ranges: [.init(lower: 0, upper: 10)])]
        return state
    }
}

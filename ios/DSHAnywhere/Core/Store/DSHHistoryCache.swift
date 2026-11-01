import Foundation
import CryptoKit

/// A durable, device-local transcript snapshot.  It is deliberately scoped to
/// one paired machine and contains no credentials, request receipts, pending
/// approvals, or connection state.
public struct DSHHistoryCacheRecord: Codable, Sendable, Equatable {
    public let sessionID: String
    /// Optional server-provided transcript fingerprint.  It is opaque to iOS
    /// and lets a later protocol revision prove that an unchanged cache still
    /// represents the same durable history.
    public var fingerprint: String?
    public var summary: DSHSessionSummary?
    public var content: DSHHistoryContent
    public var coverage: DSHHistoryCoverage?
    public var savedAt: Date

    public init(state: DSHStoreState, session: String, fingerprint: String? = nil, savedAt: Date = .now) {
        self.sessionID = session
        self.fingerprint = fingerprint.flatMap { $0.utf8.count <= 512 ? $0 : nil }
        self.summary = state.sessions.first(where: { $0.id == session })
        self.content = DSHHistoryContent(state, session: session)
        self.coverage = state.historyCoverage?[session]
        self.savedAt = savedAt
        sanitize()
    }

    public init(state: DSHStoreState, sessionID: String, savedAt: Date = .now) {
        self.init(state: state, session: sessionID, savedAt: savedAt)
    }

    /// Restoring a cache is only for reading while the Mac is contacted.  Do
    /// not revive a turn, approval, or goal activation from a previous launch.
    public mutating func sanitize() {
        if var summary { summary.running = false; self.summary = summary }
        if fingerprint?.utf8.count ?? 0 > 512 { fingerprint = nil }
        content.liveGoal = false
        content.permission = nil
        content.tools = content.tools?.map(Self.settle)
    }

    public func restore(into state: inout DSHStoreState) {
        var safe = self
        safe.sanitize()
        safe.content.restore(into: &state, session: sessionID)
        if state.historyCoverage == nil { state.historyCoverage = [:] }
        if let coverage = safe.coverage { state.historyCoverage?[sessionID] = coverage }
        if let summary = safe.summary {
            if let index = state.sessions.firstIndex(where: { $0.id == sessionID }) {
                state.sessions[index] = summary
            } else {
                state.sessions.append(summary)
            }
        }
        state.turnStateBySession.removeValue(forKey: sessionID)
        state.liveGoalSessions?.remove(sessionID)
        // Cache snapshots do not contain approvals or questions.  Leave any
        // requests received by the current connection alone; they are owned
        // by the live decision stream rather than transcript persistence.
    }

    private static func settle(_ tool: DSHToolActivity) -> DSHToolActivity {
        var safe = tool
        if safe.status == "running" || safe.status == "stopping" { safe.status = "unknown" }
        safe.children = safe.children?.map(settle)
        return safe
    }
}

/// Small file-backed cache for conversation history. Corrupt and obsolete
/// files are cache misses: they never affect the separate mutation journal.
public actor DSHHistoryCache {
    public static let maximumRecordBytes = 50 * 1024 * 1024
    public static let maximumTotalBytes = 150 * 1024 * 1024

    private struct Stored: Codable {
        let scope: String
        let record: DSHHistoryCacheRecord
    }

    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory.appendingPathComponent("history-cache", isDirectory: true)
        self.fileManager = fileManager
    }

    public func load(scope: String, session: String) -> DSHHistoryCacheRecord? {
        guard valid(scope), valid(session) else { return nil }
        let url = fileURL(scope: scope, session: session)
        guard let data = try? Data(contentsOf: url), data.count <= Self.maximumRecordBytes,
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.scope == scope, stored.record.sessionID == session else {
            discard(url)
            return nil
        }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return stored.record
    }

    public func save(_ record: DSHHistoryCacheRecord, scope: String) throws {
        guard valid(scope), valid(record.sessionID) else { return }
        var safe = record
        safe.sanitize()
        let data = try JSONEncoder().encode(Stored(scope: scope, record: safe))
        guard data.count <= Self.maximumRecordBytes else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var cacheDirectory = directory
        try? cacheDirectory.setResourceValues(values)
        try data.write(to: fileURL(scope: scope, session: record.sessionID), options: [.atomic, .completeFileProtection])
        try evictIfNeeded()
    }

    public func summaries(scope: String) -> [DSHSessionSummary] {
        guard valid(scope), let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url), data.count <= Self.maximumRecordBytes,
                  let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.scope == scope else { return nil }
            var summary = stored.record.summary
            summary?.running = false
            return summary
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func remove(scope: String) throws {
        guard valid(scope), let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.scope == scope else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private func fileURL(scope: String, session: String) -> URL {
        let digest = SHA256.hash(data: Data("\(scope)\u{0}\(session)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("history-\(digest).json")
    }

    private func valid(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 512 }

    private func discard(_ url: URL) { try? fileManager.removeItem(at: url) }

    private func evictIfNeeded() throws {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        var entries: [(url: URL, bytes: Int, date: Date)] = []
        var total = 0
        for url in files {
            let values = try? url.resourceValues(forKeys: keys)
            let bytes = values?.fileSize ?? 0
            total += bytes
            entries.append((url, bytes, values?.contentModificationDate ?? .distantPast))
        }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > Self.maximumTotalBytes {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.bytes
        }
    }
}

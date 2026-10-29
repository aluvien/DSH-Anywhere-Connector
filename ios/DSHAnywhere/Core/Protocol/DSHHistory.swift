import Foundation

public struct DSHSearchHit: Codable, Identifiable, Sendable, Equatable {
    public let sessionId: String
    public let nativeSequence: Int64?
    public let time: Int64?
    public let type: String?
    public let surface: String?
    public let snippet: String
    public let session: DSHSessionSummary?
    public var id: String { "\(sessionId):\(nativeSequence.map(String.init) ?? "session")" }
}
public struct DSHSearchResults: Codable, Sendable, Equatable {
    public let query: String
    public let scopeSessionId: String?
    public var items: [DSHSearchHit]
    public let hasMore: Bool
    public let nextCursor: String?
    public let bounded: Bool?
}
public struct DSHHistoryWindow: Codable, Sendable, Equatable {
    public let sessionId: String
    public let throughSeq: Int64
    public let fromSeq: Int64
    public let toSeq: Int64
    public let hasMore: Bool
    public var isValid: Bool {
        throughSeq >= -1 && throughSeq < 9_007_199_254_740_991 && fromSeq >= 0 && toSeq <= throughSeq &&
        ((toSeq == -1 && fromSeq == 0 && !hasMore) || (toSeq >= fromSeq && hasMore == (fromSeq > 0)))
    }
}
public struct DSHHistoryFocus: Codable, Sendable, Equatable, Identifiable {
    public let nativeSequence: Int64
    public let time: Int64?
    public let type: String
    public let data: [String: DSHJSONValue]
    public var id: Int64 { nativeSequence }
}
public struct DSHHistoryRow: Codable, Sendable, Equatable {
    public let nativeSequence: Int64
    public let time: Int64?
    public let type: String
    public var payload: [String: DSHJSONValue]
}
public struct DSHHistoryPage: Codable, Sendable, Equatable {
    public let sessionId: String
    public let throughSeq: Int64
    public let fromSeq: Int64
    public let toSeq: Int64
    public let hasMore: Bool
    public let rows: [DSHHistoryRow]
    public let focus: DSHHistoryFocus?
    public var window: DSHHistoryWindow { .init(sessionId: sessionId, throughSeq: throughSeq, fromSeq: fromSeq, toSeq: toSeq, hasMore: hasMore) }
    public func events(in envelope: DSHEnvelope) -> [DSHEvent]? {
        guard window.isValid, envelope.sessionId == sessionId else { return nil }
        if let focus, !(fromSeq...max(fromSeq, toSeq)).contains(focus.nativeSequence) { return nil }
        let allowed: Set<String> = ["user.message.accepted", "assistant.message.completed", "assistant.reasoning", "tool.started", "tool.completed", "command.result", "session.model.changed", "execution.recorded", "workflow.changed"]
        var result: [DSHEvent] = []
        for row in rows {
            guard allowed.contains(row.type), row.nativeSequence >= 0, row.nativeSequence <= toSeq,
                  row.nativeSequence >= fromSeq || row.type == "execution.recorded",
                  row.payload["sessionId"] == nil || row.payload["sessionId"] == .string(sessionId) else { return nil }
            var payload = row.payload
            if row.type == "execution.recorded", payload["record"]?.executionObject["nativeSequence"] != .number(Double(row.nativeSequence)) { return nil }
            if !["execution.recorded", "workflow.changed", "assistant.reasoning"].contains(row.type) { payload["nativeSequence"] = .number(Double(row.nativeSequence)) }
            let event = DSHEvent(envelope: .init(messageId: envelope.messageId, deviceId: envelope.deviceId, machineId: envelope.machineId,
                sessionId: sessionId, historyBatchId: "page-\(envelope.messageId)", sequence: envelope.sequence, timestamp: row.time ?? envelope.timestamp, type: row.type, payload: .object(payload)))
            if case .unknown = event.kind { return nil }
            result.append(event)
        }
        return result
    }
}
public struct DSHHistoryRange: Codable, Identifiable, Sendable, Equatable {
    public var lower: Int64
    public var upper: Int64
    public var id: String { "\(lower):\(upper)" }
}
/// Only acknowledged contiguous Native ranges count as loaded. Cached rows
/// or a search result never imply that the intervening history is present.
public struct DSHHistoryCoverage: Codable, Sendable, Equatable {
    public var throughSeq: Int64 = -1
    public var ranges: [DSHHistoryRange] = []
    public var nextBefore: Int64? {
        guard let newest = ranges.last else { return nil }
        if newest.upper < throughSeq { return throughSeq + 1 }
        return newest.lower > 0 ? newest.lower : nil
    }
    public var gaps: [DSHHistoryRange] {
        var missing: [DSHHistoryRange] = zip(ranges, ranges.dropFirst()).compactMap { left, right in
            right.lower > left.upper + 1 ? .init(lower: left.upper + 1, upper: right.lower - 1) : nil
        }
        if let newest = ranges.last, newest.upper < throughSeq { missing.append(.init(lower: newest.upper + 1, upper: throughSeq)) }
        return missing
    }
    public mutating func include(_ window: DSHHistoryWindow) {
        guard window.isValid else { return }
        throughSeq = max(throughSeq, window.throughSeq)
        guard window.toSeq >= 0 else { return }
        var merged: [DSHHistoryRange] = []
        for range in (ranges + [.init(lower: window.fromSeq, upper: window.toSeq)]).sorted(by: { $0.lower < $1.lower }) {
            if let last = merged.last, range.lower <= last.upper + 1 { merged[merged.count - 1].upper = max(last.upper, range.upper) }
            else { merged.append(range) }
        }
        ranges = merged
    }
}

/// Keep transient/legacy rows by their neighbouring known Native anchors.
/// Loading an older page must not make its last user message the current turn.
func dshHistoryOrder<T>(_ values: [T], native: (T) -> Int64?) -> [T] {
    var positions = values.map { native($0).map(Double.init) }
    var index = 0
    while index < positions.count {
        if positions[index] != nil { index += 1; continue }
        let start = index
        while index < positions.count && positions[index] == nil { index += 1 }
        let left = start > 0 ? positions[start - 1] : nil
        let right = index < positions.count ? positions[index] : nil
        for offset in start..<index {
            let fraction = Double(offset - start + 1) / Double(index - start + 1)
            if let left, let right, right >= left { positions[offset] = left + (right - left) * fraction }
            else if let left { positions[offset] = left + fraction }
            else if let right { positions[offset] = right - 1 + fraction }
            else { positions[offset] = Double(offset) }
        }
    }
    return values.enumerated().sorted { a, b in
        let left = positions[a.offset] ?? 0, right = positions[b.offset] ?? 0
        return left == right ? a.offset < b.offset : left < right
    }.map(\.element)
}

import Foundation

extension DSHJSONValue {
    var executionObject: [String: DSHJSONValue] { if case .object(let value) = self { return value }; return [:] }
    var executionString: String? { if case .string(let value) = self { return value }; return nil }
    var executionNumber: Double? { if case .number(let value) = self { return value }; return nil }
    var executionInt: Int? {
        guard let value = executionNumber, value.isFinite, value.rounded() == value, abs(value) <= 9_007_199_254_740_991 else { return nil }
        return Int(value)
    }
    var executionArray: [DSHJSONValue] { if case .array(let value) = self { return value }; return [] }
    var executionPrettyJSON: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

public struct DSHExecutionRecord: Codable, Sendable, Equatable, Identifiable {
    public let nativeSequence: Int64
    public let type: String
    public let time: Int64?
    public let data: [String: DSHJSONValue]
    public var sequence: Int64?
    public var id: Int64 { nativeSequence }
    var turn: Int? { data["turn"]?.executionInt }
    var step: Int? { data["step"]?.executionInt }
    var reason: String? { data["reason"]?.executionString ?? data["reason"]?.executionObject["kind"]?.executionString }
    var title: String {
        switch type {
        case "turn/start": return "轮次 \(turn.map(String.init) ?? "—") 开始"
        case "turn/end": return "轮次 \(turn.map(String.init) ?? "—") · \(DSHExecutionNotice.reasonLabel(reason))"
        case "step/start": return "步骤 \(step.map(String.init) ?? "—") 开始"
        case "step/end": return "步骤 \(step.map(String.init) ?? "—") 结束"
        case "assistant/message": return data["interrupted"] == .bool(true) ? "保存中断前的回答" : "模型回答已提交"
        case "assistant/attempt": return "未提交的模型尝试"
        case "tool/call": return "调用工具 · \(data["name"]?.executionString ?? "未知工具")"
        case "tool/result": return "工具返回结果"
        case "tool/ptc-dispatch-start": return "子调用开始 · \(data["name"]?.executionString ?? "未知工具")"
        case "tool/ptc-dispatch": return "子调用返回 · \(data["name"]?.executionString ?? "未知工具")"
        case "llm/retry": return "安排第 \(data["retry"]?.executionInt.map(String.init) ?? "—") 次重试"
        case "llm/retry-started": return "开始重试请求"
        case "compaction/start": return "开始压缩上下文"
        case "compaction/summary": return "压缩摘要已生成"
        case "compaction/end": return data["error"] == nil ? "压缩结束" : "压缩失败"
        case "compaction/checkpoint": return "压缩已应用到上下文"
        case "compaction/prune": return "上下文裁剪记录"
        case "request/header": return "请求配置"
        case "request/context": return "模型路由与上下文容量"
        default: return type
        }
    }
    var usage: DSHJSONValue? {
        data["usage"] ?? data["stream"]?.executionArray.reversed().first(where: { $0.executionObject["chunk"]?.executionObject["type"] == .string("usage") })?.executionObject["chunk"]?.executionObject["usage"]
    }
    var finish: DSHJSONValue? {
        data["stream"]?.executionArray.reversed().first(where: { $0.executionObject["chunk"]?.executionObject["type"] == .string("finish") })?.executionObject["chunk"]?.executionObject["reason"]
    }
    var firstTokenTime: Double? {
        for value in data["stream"]?.executionArray ?? [] {
            let record = value.executionObject
            let kind = record["type"]?.executionString
            if ["text-chunks", "reasoning-chunks", "tool-call-chunks"].contains(kind) {
                var time = record["time0"]?.executionNumber ?? .nan
                let fragments = record[kind == "tool-call-chunks" ? "args" : "texts"]?.executionArray ?? []
                let dt = record["dt"]?.executionArray ?? []
                guard time.isFinite, dt.count >= max(0, fragments.count - 1),
                      dt.allSatisfy({ $0.executionNumber.map { $0.isFinite && $0 >= 0 } ?? false }) else { continue }
                for (index, fragment) in fragments.enumerated() {
                    if index > 0, dt.indices.contains(index - 1) { time += dt[index - 1].executionNumber ?? .nan }
                    if !(fragment.executionString ?? "").isEmpty || (kind == "tool-call-chunks" && record["name"]?.executionString != nil) {
                        if time.isFinite { return time }
                    }
                }
            } else if kind == "chunk" {
                let chunk = record["chunk"]?.executionObject ?? [:]
                if (["text-delta", "reasoning-delta"].contains(chunk["type"]?.executionString) && !(chunk["text"]?.executionString ?? "").isEmpty) ||
                    (chunk["type"] == .string("tool-call-delta") && (chunk["name"]?.executionString != nil || !(chunk["argumentsDelta"]?.executionString ?? "").isEmpty)) {
                    return record["time"]?.executionNumber
                }
            }
        }
        return nil
    }
    /// Settled block-end content wins over deltas; it must never be appended
    /// a second time. Attempts remain separate from committed chat messages.
    var output: (text: String, reasoning: String) {
        var blocks = data["message"]?.executionObject["content"]?.executionArray
        if type == "compaction/summary" { blocks = data["summary"]?.executionArray }
        if blocks == nil {
            var indexed: [Int: (kind: String, text: String)] = [:]
            for value in data["stream"]?.executionArray ?? [] {
                let record = value.executionObject, kind = record["type"]?.executionString
                if let index = record["index"]?.executionInt, kind == "text-chunks" || kind == "reasoning-chunks" {
                    let old = indexed[index]?.text ?? ""
                    indexed[index] = (kind == "text-chunks" ? "text" : "reasoning", old + (record["texts"]?.executionArray ?? []).compactMap(\.executionString).joined())
                } else if kind == "chunk" {
                    let chunk = record["chunk"]?.executionObject ?? [:]
                    guard let index = chunk["index"]?.executionInt else { continue }
                    if chunk["type"] == .string("block-end") {
                        let block = chunk["block"]?.executionObject ?? [:]
                        if let kind = block["type"]?.executionString, ["text", "reasoning"].contains(kind) { indexed[index] = (kind, block["text"]?.executionString ?? "") }
                    } else if chunk["type"] == .string("text-delta") || chunk["type"] == .string("reasoning-delta") {
                        indexed[index] = (chunk["type"] == .string("text-delta") ? "text" : "reasoning", (indexed[index]?.text ?? "") + (chunk["text"]?.executionString ?? ""))
                    }
                }
            }
            blocks = indexed.keys.sorted().compactMap { index in indexed[index].map { .object(["type": .string($0.kind), "text": .string($0.text)]) } }
        }
        func joined(_ kind: String) -> String { (blocks ?? []).filter { $0.executionObject["type"] == .string(kind) }.compactMap { $0.executionObject["text"]?.executionString }.joined() }
        return (joined("text"), joined("reasoning"))
    }
}

public struct DSHExecutionRecorded: Codable, Sendable, Equatable {
    public let sessionId: String
    public let record: DSHExecutionRecord
    public let inTranscript: Bool?
}
public struct DSHExecutionLifecycle: Codable, Sendable, Equatable {
    public struct OpenTurn: Codable, Sendable, Equatable { public let turn: Int64; public let startedAt: Double? }
    public let createdAt: Double
    public let inheritedEventCount: Int64
    public let throughSeq: Int64
    public let ownEventCount: Int64
    public let turnsStarted: Int64
    public let turnsEnded: Int64
    public let measuredTurns: Int64
    public let endedTurnMilliseconds: Double
    public let timingIncomplete: Bool
    public let assistantMessages: Int64
    public let toolCalls: Int64
    public let lastActivityAt: Double?
    public let lastEndKind: String?
    public let openTurn: OpenTurn?
    var endDescription: String? {
        switch lastEndKind {
        case "completed": "已完成"; case "aborted": "已取消"; case "error": "失败"; case "max-tokens": "达到输出上限"; case "interrupted": "已中断"; case .some: "原生结束原因未识别"; case nil: nil
        }
    }
}
public struct DSHExecutionPage: Codable, Sendable, Equatable {
    public let sessionId: String
    public let records: [DSHExecutionRecord]
    public var lifecycle: DSHExecutionLifecycle? = nil
    public let hasMore: Bool
    public let beforeSeq: Int64?
}

struct DSHExecutionGroup: Identifiable {
    let id: String
    let title: String
    let records: [DSHExecutionRecord]
    static func build(_ records: [DSHExecutionRecord]) -> [DSHExecutionGroup] {
        let ordered = records.sorted { $0.nativeSequence < $1.nativeSequence }
        var compactTurns: [String: Int] = [:]
        for record in ordered {
            if let id = record.data["compactionId"]?.executionString, let turn = record.turn { compactTurns[id] = turn }
        }
        var currentTurn: Int?
        var groups: [String: [DSHExecutionRecord]] = [:], ids: [String] = []
        for record in ordered {
            if record.type == "turn/start" { currentTurn = record.turn }
            let compact = record.data["compactionId"]?.executionString
            let owner = record.turn ?? compact.flatMap { compactTurns[$0] } ?? (compact == nil ? currentTurn : nil)
            let id = owner.map { "turn:\($0)" } ?? compact.map { "compaction:\($0)" } ?? "session"
            if groups[id] == nil { ids.append(id) }
            groups[id, default: []].append(record)
            if record.type == "turn/end", currentTurn == record.turn { currentTurn = nil }
        }
        return ids.map { id in
            let values = groups[id] ?? []
            let title: String
            if id.hasPrefix("turn:") {
                let turn = id.dropFirst(5)
                let end = values.last { $0.type == "turn/end" }
                title = "轮次 \(turn) · \(end.map { DSHExecutionNotice.reasonLabel($0.reason) } ?? "未见结束记录")"
            } else { title = id.hasPrefix("compaction:") ? "独立上下文压缩" : "会话请求设置" }
            return DSHExecutionGroup(id: id, title: title, records: values)
        }
    }
}

public struct DSHExecutionNotice: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let records: [DSHExecutionRecord]
    public let boundary: DSHExecutionRecord?
    public var sequence: Int64? {
        if kind == "compaction", let checkpoint = records.first(where: { $0.type == "compaction/checkpoint" && $0.sequence != nil }) { return checkpoint.sequence }
        return records.compactMap(\.sequence).first
    }
    var nativeSequence: Int64? {
        if kind == "compaction", let checkpoint = records.first(where: { $0.type == "compaction/checkpoint" }) { return checkpoint.nativeSequence }
        return records.first?.nativeSequence
    }
    var latestRetry: DSHExecutionRecord? { records.last { $0.type == "llm/retry" } }
    var retryState: String {
        guard let latestRetry else { return "unknown" }
        if records.contains(where: { $0.type == "llm/retry-started" && $0.data["retry"] == latestRetry.data["retry"] && $0.nativeSequence > latestRetry.nativeSequence }) { return "started" }
        return boundary == nil ? "scheduled" : "cancelled"
    }
    func canCountDown(connected: Bool, sessionRunning: Bool, latestTurn: Int?) -> Bool {
        guard connected, sessionRunning, retryState == "scheduled", let retry = latestRetry, retry.time != nil,
              let delay = retry.data["delayMs"]?.executionNumber, delay.isFinite, delay >= 0,
              let owner = retry.turn, latestTurn == owner else { return false }
        return true
    }
    static func reasonLabel(_ reason: String?) -> String {
        switch reason {
        case "completed": return "完成"
        case "aborted": return "已取消"
        case "blocked": return "受阻"
        case "error": return "失败"
        case "max-tokens": return "达到输出上限"
        case "interrupted": return "异常中断"
        default: return reason ?? "结束原因未知"
        }
    }
    static func build(_ records: [DSHExecutionRecord]) -> [DSHExecutionNotice] {
        let ordered = records.sorted { $0.nativeSequence < $1.nativeSequence }
        var groups: [String: [DSHExecutionRecord]] = [:]
        for record in ordered {
            let key: String?
            if record.type.hasPrefix("llm/retry"), let id = record.data["retryId"]?.executionString { key = "retry:" + id }
            else if record.type.hasPrefix("compaction/"), let id = record.data["compactionId"]?.executionString { key = "compaction:" + id }
            else if record.type == "compaction/prune" { key = "prune:\(record.id)" }
            else if record.type == "turn/end", record.reason != "completed" { key = "turn:\(record.id)" }
            else { key = nil }
            if let key { groups[key, default: []].append(record) }
        }
        return groups.map { id, values in
            let last = values.last { $0.type == "llm/retry" }
            let boundary = last.flatMap { retry in ordered.first { candidate in
                retry.turn != nil &&
                candidate.nativeSequence > retry.nativeSequence && candidate.turn == retry.turn &&
                    (candidate.type == "turn/end" || (candidate.type == "step/end" && candidate.step == retry.step))
            } }
            return DSHExecutionNotice(id: id, kind: String(id.prefix(while: { $0 != ":" })), records: values, boundary: boundary)
        }.sorted { ($0.records.first?.nativeSequence ?? 0) < ($1.records.first?.nativeSequence ?? 0) }
    }
}

import Foundation

public struct DSHScheduleRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let prompt: String
    public let scheduledAt: String
    public let afterSeconds: Int?
    public let everySeconds: Int?
    public var date: Date? {
        (try? Date(scheduledAt, strategy: .iso8601)) ?? (try? Date(scheduledAt, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
    public var frequencyLabel: String {
        func duration(_ seconds: Int) -> String {
            for (unit, name) in [(86400, "天"), (3600, "小时"), (60, "分钟")] where seconds % unit == 0 { return "\(seconds / unit) \(name)" }
            return "\(seconds) 秒"
        }
        if kind == "every", let everySeconds { return "每 \(duration(everySeconds))" }
        if kind == "after", let afterSeconds { return "延时 \(duration(afterSeconds)) · 一次" }
        return "指定时间 · 一次"
    }
}
public struct DSHScheduleProjection: Codable, Sendable, Equatable {
    public let sessionId: String
    public let epoch: String
    public let seq: Int64
    public var available: Bool
    public let supported: Bool
    public let items: [DSHScheduleRecord]
}

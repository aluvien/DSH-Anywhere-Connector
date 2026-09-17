import Foundation

/// A small JSON value type keeps the wire protocol forward compatible.  In
/// particular, payloads for event types that this client does not know yet are
/// retained instead of being discarded.
public enum DSHJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([DSHJSONValue])
    case object([String: DSHJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DSHJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: DSHJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public struct DSHEnvelope: Codable, Sendable, Equatable {
    public let version: Int
    public let messageId: String
    public let deviceId: String
    public let machineId: String
    public let sessionId: String?
    public let sequence: Int64
    /// Milliseconds since Unix epoch, as used by the JavaScript side.
    public let timestamp: Int64
    public let type: String
    public let payload: DSHJSONValue

    public init(version: Int = 1, messageId: String, deviceId: String,
                machineId: String, sessionId: String? = nil,
                sequence: Int64, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
                type: String, payload: DSHJSONValue = .object([:])) {
        self.version = version
        self.messageId = messageId
        self.deviceId = deviceId
        self.machineId = machineId
        self.sessionId = sessionId
        self.sequence = sequence
        self.timestamp = timestamp
        self.type = type
        self.payload = payload
    }

    // The relay protocol uses optional fields, not JSON nulls.  Swift's
    // synthesized Codable implementation emits `sessionId: null`, which is
    // rejected by the relay's strict object schemas.
    private enum CodingKeys: String, CodingKey {
        case version, messageId, deviceId, machineId, sessionId, sequence, timestamp, type, payload
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(messageId, forKey: .messageId)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(machineId, forKey: .machineId)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(type, forKey: .type)
        try container.encode(payload, forKey: .payload)
    }
}

public struct DSHCommand: Codable, Sendable, Equatable {
    public let version: Int
    public let requestId: String
    public let deviceId: String
    public let machineId: String
    public let sessionId: String?
    public let timestamp: Int64
    public let type: String
    public let payload: DSHJSONValue

    public init(version: Int = 1, requestId: String = UUID().uuidString,
                deviceId: String, machineId: String, sessionId: String? = nil,
                timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
                type: String, payload: DSHJSONValue = .object([:])) {
        self.version = version
        self.requestId = requestId
        self.deviceId = deviceId
        self.machineId = machineId
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.type = type
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case version, requestId, deviceId, machineId, sessionId, timestamp, type, payload
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(machineId, forKey: .machineId)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(type, forKey: .type)
        try container.encode(payload, forKey: .payload)
    }

    public static func resume(deviceId: String, machineId: String, lastSequence: Int64) -> DSHCommand {
        DSHCommand(deviceId: deviceId, machineId: machineId, type: "connection.resume",
                    payload: .object(["lastSequence": .number(Double(lastSequence))]))
    }

    public static func sendPrompt(deviceId: String, machineId: String, sessionId: String,
                                  text: String, requestId: String = UUID().uuidString) -> DSHCommand {
        DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                   sessionId: sessionId, type: "prompt.send",
                   payload: .object(["text": .string(text)]))
    }

    public static func sendPrompt(deviceId: String, machineId: String, sessionId: String,
                                  text: String, attachments: [DSHJSONValue] = [],
                                  mode: String = "queue", requestId: String = UUID().uuidString) -> DSHCommand {
        var payload: [String: DSHJSONValue] = [
            "text": .string(text),
            "mode": .string(mode)
        ]
        if !attachments.isEmpty {
            // The Harness treats `content` as the canonical multipart prompt.
            // Keep the text in that same array; sending it only beside a file
            // reference makes the bridge accept the upload while silently
            // dropping the text part.
            var content: [DSHJSONValue] = []
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                content.append(.object(["type": .string("text"), "text": .string(text)]))
            }
            content.append(contentsOf: attachments)
            payload["content"] = .array(content)
        }
        return DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                          sessionId: sessionId, type: "prompt.send", payload: .object(payload))
    }

    public static func listSessions(deviceId: String, machineId: String,
                                    includeArchived: Bool = false) -> DSHCommand {
        DSHCommand(deviceId: deviceId, machineId: machineId, type: "session.list",
                   payload: .object(["includeArchived": .bool(includeArchived)]))
    }

    /// Requests the durable transcript for one existing session. The Connector
    /// asks the Mac bridge to inspect that session and forwards the normalized
    /// history as ordinary transcript events over the existing socket.
    public static func openSession(deviceId: String, machineId: String,
                                   sessionId: String,
                                   requestId: String = UUID().uuidString) -> DSHCommand {
        DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                   sessionId: sessionId, type: "session.open",
                   payload: .object(["sessionId": .string(sessionId)]))
    }

    public static func archiveSession(deviceId: String, machineId: String, sessionId: String,
                                      archived: Bool, requestId: String = UUID().uuidString) -> DSHCommand {
        DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                   sessionId: sessionId, type: "session.archive",
                   payload: .object(["archived": .bool(archived)]))
    }

    public static func selectModel(deviceId: String, machineId: String, sessionId: String,
                                   provider: String, model: String, reasoningEffort: String? = nil,
                                   requestId: String = UUID().uuidString) -> DSHCommand {
        var payload: [String: DSHJSONValue] = ["provider": .string(provider), "model": .string(model)]
        if let reasoningEffort { payload["reasoningEffort"] = .string(reasoningEffort) }
        return DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                          sessionId: sessionId, type: "session.model", payload: .object(payload))
    }

    public static func renameWorkspace(deviceId: String, machineId: String,
                                       workspaceId: String, title: String,
                                       requestId: String = UUID().uuidString) -> DSHCommand {
        DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                   type: "workspace.rename",
                   payload: .object(["workspaceId": .string(workspaceId),
                                     "title": .string(title)]))
    }

    public static func deleteWorkspace(deviceId: String, machineId: String,
                                       workspaceId: String,
                                       requestId: String = UUID().uuidString) -> DSHCommand {
        DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                   type: "workspace.delete",
                   payload: .object(["workspaceId": .string(workspaceId)]))
    }

    public static func modelCatalog(deviceId: String, machineId: String,
                                    requestId: String = UUID().uuidString) -> DSHCommand {
        DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                   type: "model.catalog", payload: .object([:]))
    }

    public static func executeCommand(deviceId: String, machineId: String, sessionId: String,
                                      line: String, attachments: [DSHJSONValue] = [],
                                      requestId: String = UUID().uuidString) -> DSHCommand {
        var payload: [String: DSHJSONValue] = ["line": .string(line)]
        if !attachments.isEmpty { payload["attachments"] = .array(attachments) }
        return DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                          sessionId: sessionId, type: "command.execute", payload: .object(payload))
    }

    public static func setPermission(deviceId: String, machineId: String, sessionId: String,
                                     mode: String, requestId: String = UUID().uuidString) -> DSHCommand {
        DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                   sessionId: sessionId, type: "permission.set",
                   payload: .object(["mode": .string(mode)]))
    }

    public static func uploadAttachment(deviceId: String, machineId: String, sessionId: String,
                                        name: String, data: Data,
                                        requestId: String = UUID().uuidString) -> DSHCommand {
        DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                   sessionId: sessionId, type: "attachment.upload",
                   payload: .object(["name": .string(name), "data": .string(data.base64EncodedString())]))
    }

    public static func cancelTurn(deviceId: String, machineId: String, sessionId: String,
                                  requestId: String = UUID().uuidString) -> DSHCommand {
        DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                   sessionId: sessionId, type: "turn.cancel")
    }

    public static func decideApproval(deviceId: String, machineId: String, sessionId: String,
                                      approvalId: String, allow: Bool,
                                      requestId: String = UUID().uuidString) -> DSHCommand {
        DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                   sessionId: sessionId, type: "approval.decide",
                   payload: .object(["approvalId": .string(approvalId), "allow": .bool(allow)]))
    }

    /// One answered question. `selected` carries option labels verbatim, which
    /// is what the Harness echoes back into the model's tool result.
    public static func answerQuestion(deviceId: String, machineId: String, sessionId: String,
                                      questionId: String, answers: [DSHQuestionAnswer],
                                      requestId: String = UUID().uuidString) -> DSHCommand {
        DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                   sessionId: sessionId, type: "question.answer",
                   payload: .object([
                       "questionId": .string(questionId),
                       "answers": .array(answers.map { $0.jsonValue }),
                   ]))
    }
}

/// One question's answer as sent back to the bridge.
public struct DSHQuestionAnswer: Sendable, Equatable {
    public let id: String
    public let selected: [String]
    public let custom: String?

    public init(id: String, selected: [String], custom: String? = nil) {
        self.id = id; self.selected = selected; self.custom = custom
    }

    var jsonValue: DSHJSONValue {
        .object(jsonObject)
    }

    private var jsonObject: [String: DSHJSONValue] {
        var object: [String: DSHJSONValue] = [
            "id": .string(id),
            "selected": .array(selected.map { .string($0) }),
        ]
        if let custom { object["custom"] = .string(custom) }
        return object
    }
}

/// Scanned `dshanywhere://pair` payload. Mirrors `parsePairingLink` in
/// packages/protocol so the QR format keeps a single definition across the
/// TypeScript connector and this client.
/// Exactly one credential authorises a pairing: the long-lived secret, or a
/// single-use code minted by the Mac. An enum keeps "both" and "neither"
/// unrepresentable.
public enum DSHPairingCredential: Equatable, Sendable {
    case secret(String)
    case code(String)

    /// Codes are 8 characters drawn from an alphabet without 0/O/1/I/L; secrets
    /// are 43-character base64url. The lengths cannot overlap, so a single text
    /// field can accept either without asking the user to pick a mode.
    public static func detect(_ raw: String) -> DSHPairingCredential? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()
        let isCode = upper.count == 8 && upper.allSatisfy { codeAlphabet.contains($0) }
        return isCode ? .code(upper) : .secret(trimmed)
    }

    public static let codeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
}

public struct DSHPairingLink: Equatable, Sendable {
    public let relay: String
    public let machineId: String
    public let credential: DSHPairingCredential

    /// Returns nil for anything that is not a complete pairing link, so the
    /// scanner can keep looking instead of filling in half a credential.
    public init?(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "dshanywhere",
              let queryItems = components.queryItems else { return nil }

        func value(_ name: String) -> String? {
            queryItems.first { $0.name == name }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let relay = value("relay"), !relay.isEmpty,
              let machineId = value("machineId"), !machineId.isEmpty,
              let relayURL = URL(string: relay),
              let scheme = relayURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }

        // A link carrying both is ambiguous; the code wins, matching
        // parsePairingLink in packages/protocol.
        let code = value("code")?.uppercased() ?? ""
        let secret = value("secret") ?? ""
        guard let credential = code.isEmpty
            ? (secret.isEmpty ? nil : DSHPairingCredential.secret(secret))
            : DSHPairingCredential.code(code) else { return nil }

        self.relay = relay
        self.machineId = machineId
        self.credential = credential
    }
}

/// What arrived in a transcript, before any grouping. Declared at file scope
/// because Swift cannot nest a type inside a generic function.
private enum DSHTranscriptArrival {
    case message(DSHChatMessage)
    case tool(DSHToolActivity)
    case command(DSHCommandResult)
    case modelChange(DSHModelChangeNotice)

    var sequence: Int64 {
        switch self {
        case .message(let message): return message.sequence ?? 0
        case .tool(let tool): return tool.sequence ?? 0
        case .command(let result): return result.sequence ?? 0
        case .modelChange(let notice): return notice.sequence
        }
    }

}

/// The language the interface is shown in.
public enum DSHLanguage: String, CaseIterable, Sendable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    /// nil means "follow the device".
    public var locale: Locale? {
        self == .system ? nil : Locale(identifier: rawValue)
    }

    /// Each option is written in its own language, so it stays readable even
    /// when the interface is in a language you cannot read.
    public var displayName: String {
        switch self {
        case .system: return DSHLocalization.string("Follow System")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

/// Localizes strings that are built outside SwiftUI.
///
/// `Text("…")` follows the environment locale, so views need no help. Plain
/// strings produced by helpers (`permissionLabel`, the connection state, the
/// model's error messages) do not, so they come through here.
public enum DSHLocalization {
    /// Guarded by `lock`. The `nonisolated(unsafe)` annotation is what tells the
    /// compiler that the locking is the safety argument — it is the supported
    /// escape hatch, not a way of ignoring the check.
    nonisolated(unsafe) private static var storedLanguage: DSHLanguage = .system
    private static let lock = NSLock()

    /// Kept in step with the stored preference by the app model.
    public static var language: DSHLanguage {
        get { lock.withLock { storedLanguage } }
        set { lock.withLock { storedLanguage = newValue } }
    }

    private static var selectedBundle: Bundle? {
        guard let locale = language.locale,
              let path = Bundle.main.path(forResource: locale.identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle
    }

    public static func string(_ key: String) -> String {
        selectedBundle?.localizedString(forKey: key, value: key, table: nil)
            ?? Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}

/// One row of the transcript, in the order the events actually arrived.
public enum DSHTranscriptEntry: Identifiable, Sendable, Equatable {
    case turn(DSHTranscriptBlock)
    case tool(DSHToolActivity)
    case command(DSHCommandResult)
    case modelChange(DSHModelChangeNotice)

    public var id: String {
        switch self {
        case .turn(let block): return "turn-\(block.id)"
        case .tool(let tool): return "tool-\(tool.id)"
        case .command(let result): return "command-\(result.id)"
        case .modelChange(let notice): return "model-change-\(notice.id)"
        }
    }

    var sequence: Int64 {
        switch self {
        case .turn(let block): return block.sequence
        case .tool(let tool): return tool.sequence ?? 0
        case .command(let result): return result.sequence ?? 0
        case .modelChange(let notice): return notice.sequence
        }
    }
}

public extension Array where Element == DSHChatMessage {
    /// Messages and tool calls interleaved by arrival sequence.
    ///
    /// Rendering them as two separate runs put every tool call after every
    /// message, which is not the order the turn happened in: in reality the
    /// model writes, calls a tool, writes again, and so on.
    func transcriptEntries(with tools: [DSHToolActivity],
                           commandResults: [DSHCommandResult] = [],
                           modelChanges: [DSHModelChangeNotice] = []) -> [DSHTranscriptEntry] {
        // Stable by construction: a tie keeps arrival order. Sorting on the
        // sequence alone is not enough, because state persisted before
        // sequences existed carries none, and any arbitrary tie-break (id
        // order, say) would scramble the whole transcript on upgrade.
        var ordered: [(order: Int, arrival: DSHTranscriptArrival)] = []
        for message in self { ordered.append((ordered.count, .message(message))) }
        for tool in tools { ordered.append((ordered.count, .tool(tool))) }
        for result in commandResults { ordered.append((ordered.count, .command(result))) }
        for notice in modelChanges { ordered.append((ordered.count, .modelChange(notice))) }
        ordered.sort { left, right in
            left.arrival.sequence == right.arrival.sequence
                ? left.order < right.order
                : left.arrival.sequence < right.arrival.sequence
        }
        let arrivals = ordered.map(\.arrival)

        var entries: [DSHTranscriptEntry] = []
        var run: [DSHChatMessage] = []
        func flushRun() {
            guard let first = run.first else { return }
            entries.append(.turn(DSHTranscriptBlock(id: first.id, messages: run)))
            run = []
        }

        for arrival in arrivals {
            switch arrival {
            case .message(let message):
                if message.role == .assistant {
                    run.append(message)
                } else {
                    // A user message stands alone and ends any assistant run.
                    flushRun()
                    entries.append(.turn(DSHTranscriptBlock(id: message.id, messages: [message])))
                }
            case .tool(let tool):
                // Break the run here. Grouping blindly merged a whole turn's
                // messages into one block, which pushed every call made between
                // them to the end — the very clumping this ordering is for.
                flushRun()
                entries.append(.tool(tool))
            case .command(let result):
                // Command acknowledgements are transcript content too. Keep
                // them at the event's original sequence instead of rendering
                // a second array after all messages (which pinned every
                // "Command completed" card to the bottom of the conversation).
                flushRun()
                entries.append(.command(result))
            case .modelChange(let notice):
                flushRun()
                entries.append(.modelChange(notice))
            }
        }
        flushRun()
        return entries
    }
}

/// One rendered unit: an assistant turn with the tool calls it made folded
/// in, or any other entry standing alone.
public enum DSHTranscriptSection: Identifiable, Sendable, Equatable {
    case turn(block: DSHTranscriptBlock, tools: [DSHToolActivity])
    case row(DSHTranscriptEntry)

    public var id: String {
        switch self {
        case .turn(let block, _): return "section-turn-\(block.id)"
        case .row(let entry): return "section-\(entry.id)"
        }
    }
}

public extension Array where Element == DSHTranscriptEntry {
    /// Folds each tool call into the most recent assistant turn, so one reply
    /// reads as one unit: the thinking row on top expands to the reasoning
    /// plus everything the turn ran, and only final text stays outside.
    /// User turns, commands and model notices always stand alone; a tool with
    /// no preceding assistant turn (history edge) does too.
    func groupedTurns() -> [DSHTranscriptSection] {
        var sections: [DSHTranscriptSection] = []
        var openBlock: DSHTranscriptBlock?
        var openTools: [DSHToolActivity] = []
        func flushOpen() {
            guard let block = openBlock else { return }
            sections.append(.turn(block: block, tools: openTools))
            openBlock = nil
            openTools = []
        }
        for entry in self {
            switch entry {
            case .turn(let block) where !block.isUserTurn:
                flushOpen()
                openBlock = block
            case .tool(let tool) where openBlock != nil:
                openTools.append(tool)
            default:
                flushOpen()
                sections.append(.row(entry))
            }
        }
        flushOpen()
        return sections.mergingReasoningOnlyTurns()
    }
}

public extension Array where Element == DSHTranscriptSection {
    /// Folds reasoning-only turns (think steps that produced no answer text of
    /// their own) into the turn that follows them. A long agentic turn arrives
    /// as think → tool → think → tool …, which the entry ordering keeps as
    /// separate turns so tools stay at their true positions — but rendering
    /// one "思考" row per think step buries the conversation. After the fold,
    /// one logical turn renders one timeline row holding all of its reasoning
    /// and tools, with only the final answers outside.
    /// A trailing reasoning-only turn (live streaming, tools still running)
    /// is kept as its own section so live progress is never hidden. Nothing
    /// else breaks the fold — not user turns, command cards, or model-change
    /// notices: an interruption between a think step and its answer must not
    /// strand a lone "思考" row, so those rows render in place while the
    /// pending think attaches to the next visible assistant turn. (A think
    /// step from a cancelled turn can land in the next timeline in that
    /// rare case; it stays folded shut, which beats a permanent stray row.)
    /// Orphan tools do NOT break the fold either: with pending think around,
    /// the tool belongs to it.
    func mergingReasoningOnlyTurns() -> [DSHTranscriptSection] {
        var merged: [DSHTranscriptSection] = []
        var pendingMessages: [DSHChatMessage] = []
        var pendingTools: [DSHToolActivity] = []
        func flushPendingAsOwnSection() {
            guard !pendingMessages.isEmpty || !pendingTools.isEmpty else { return }
            merged.append(.turn(
                block: DSHTranscriptBlock(
                    id: pendingMessages.first?.id ?? UUID().uuidString,
                    messages: pendingMessages),
                tools: pendingTools))
            pendingMessages = []
            pendingTools = []
        }
        for section in self {
            switch section {
            case .turn(let block, let tools) where block.visibleMessages.isEmpty:
                pendingMessages += block.messages
                pendingTools += tools
            case .turn(let block, let tools):
                merged.append(.turn(
                    block: DSHTranscriptBlock(id: block.id,
                                              messages: pendingMessages + block.messages),
                    tools: pendingTools + tools))
                pendingMessages = []
                pendingTools = []
            case .row(.turn), .row(.modelChange), .row(.command):
                merged.append(section)
            case .row(.tool(let tool)) where !pendingMessages.isEmpty || !pendingTools.isEmpty:
                pendingTools.append(tool)
            default:
                flushPendingAsOwnSection()
                merged.append(section)
            }
        }
        flushPendingAsOwnSection()
        return merged
    }
}

/// Relay messages deliberately wrap the existing Harness protocol. Keeping the
/// wrapper separate means a Relay acknowledgement can never be mistaken for a
/// Harness event by the store.
public enum DSHRelayRole: String, Codable, Sendable, Equatable {
    case machine
    case device
}

public struct DSHRelayReadyMessage: Codable, Sendable, Equatable {
    public let type: String
    public let machineId: String
    public let role: DSHRelayRole
    public let connectionId: String
    public let serverTime: Int64
}

public struct DSHRelayPresenceMessage: Codable, Sendable, Equatable {
    public let type: String
    public let machineId: String
    public let role: DSHRelayRole
    public let online: Bool
    public let deviceId: String?
    public let serverTime: Int64
}

public struct DSHRelayErrorMessage: Codable, Sendable, Equatable {
    public let type: String
    public let code: String
    public let message: String
    public let machineId: String?
    public let messageId: String?
}

public struct DSHRelayPayloadMessage: Codable, Sendable, Equatable {
    public let type: String
    public let machineId: String
    public let messageId: String
    public let sender: DSHRelayRole
    public let targetDeviceId: String?
    public let body: DSHJSONValue

    public init(machineId: String, messageId: String = UUID().uuidString,
                sender: DSHRelayRole, targetDeviceId: String? = nil, body: DSHJSONValue) {
        self.type = "relay.payload"
        self.machineId = machineId
        self.messageId = messageId
        self.sender = sender
        self.targetDeviceId = targetDeviceId
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case type, machineId, messageId, sender, targetDeviceId, body
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(machineId, forKey: .machineId)
        try container.encode(messageId, forKey: .messageId)
        try container.encode(sender, forKey: .sender)
        try container.encodeIfPresent(targetDeviceId, forKey: .targetDeviceId)
        try container.encode(body, forKey: .body)
    }

    public func decodeBody<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    public static func wrapping<T: Encodable>(machineId: String, sender: DSHRelayRole,
                                               body: T, messageId: String = UUID().uuidString) throws -> DSHRelayPayloadMessage {
        let data = try JSONEncoder().encode(body)
        let value = try JSONDecoder().decode(DSHJSONValue.self, from: data)
        return DSHRelayPayloadMessage(machineId: machineId, messageId: messageId, sender: sender, body: value)
    }
}

public enum DSHRelayMessage: Sendable, Equatable {
    case ready(DSHRelayReadyMessage)
    case presence(DSHRelayPresenceMessage)
    case payload(DSHRelayPayloadMessage)
    case error(DSHRelayErrorMessage)

    public init(from data: Data) throws {
        let decoder = JSONDecoder()
        let discriminator = try decoder.decode(DSHRelayTypeDiscriminator.self, from: data)
        switch discriminator.type {
        case "relay.ready": self = .ready(try decoder.decode(DSHRelayReadyMessage.self, from: data))
        case "relay.presence": self = .presence(try decoder.decode(DSHRelayPresenceMessage.self, from: data))
        case "relay.payload": self = .payload(try decoder.decode(DSHRelayPayloadMessage.self, from: data))
        case "relay.error": self = .error(try decoder.decode(DSHRelayErrorMessage.self, from: data))
        default: throw DSHRelayDecodingError.unknownMessageType(discriminator.type)
        }
    }
}

private struct DSHRelayTypeDiscriminator: Decodable { let type: String }

public enum DSHRelayDecodingError: Error, Sendable, Equatable {
    case unknownMessageType(String)
}

public struct DSHSessionSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var updatedAt: Int64
    public var cwd: String?
    public var workspaceId: String?
    public var workspaceName: String?
    public var archived: Bool?
    public var running: Bool?
    public var blank: Bool?
    public var parentSessionId: String?
    public var agentPreset: String?
    public var mode: String?
    public var branch: String?
    public var provider: String?
    public var model: String?
    public var reasoningEffort: String?
    public var permissionMode: String?
    public var usage: DSHSessionUsage?

    public init(id: String, title: String = "", updatedAt: Int64 = 0,
                cwd: String? = nil, workspaceId: String? = nil, workspaceName: String? = nil,
                archived: Bool? = nil, running: Bool? = nil, blank: Bool? = nil,
                parentSessionId: String? = nil, provider: String? = nil, model: String? = nil,
                reasoningEffort: String? = nil, permissionMode: String? = nil,
                agentPreset: String? = nil, mode: String? = nil, branch: String? = nil,
                usage: DSHSessionUsage? = nil) {
        self.id = id; self.title = title; self.updatedAt = updatedAt
        self.cwd = cwd; self.workspaceId = workspaceId; self.workspaceName = workspaceName
        self.archived = archived; self.running = running; self.blank = blank
        self.parentSessionId = parentSessionId; self.agentPreset = agentPreset; self.mode = mode; self.branch = branch
        self.provider = provider; self.model = model
        self.reasoningEffort = reasoningEffort; self.permissionMode = permissionMode; self.usage = usage
    }
}

public struct DSHSessionUsage: Codable, Sendable, Equatable {
    public var rounds: Int?
    public var steps: Int?
    public var inputTokens: Double?
    public var outputTokens: Double?
    public var totalTokens: Double?
    public var cacheReadTokens: Double?
    public var cacheWriteTokens: Double?
    public var cacheHitPercent: Double?
    public var tokensPerSecond: Double?
    public var contextUsed: Double?
    public var contextWindow: Double?

    public init(rounds: Int? = nil, steps: Int? = nil, inputTokens: Double? = nil,
                outputTokens: Double? = nil, totalTokens: Double? = nil,
                cacheReadTokens: Double? = nil, cacheWriteTokens: Double? = nil,
                cacheHitPercent: Double? = nil, tokensPerSecond: Double? = nil,
                contextUsed: Double? = nil, contextWindow: Double? = nil) {
        self.rounds = rounds; self.steps = steps; self.inputTokens = inputTokens
        self.outputTokens = outputTokens; self.totalTokens = totalTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheWriteTokens = cacheWriteTokens
        self.cacheHitPercent = cacheHitPercent; self.tokensPerSecond = tokensPerSecond
        self.contextUsed = contextUsed; self.contextWindow = contextWindow
    }
}

public struct DSHModelSelection: Codable, Sendable, Equatable {
    public let provider: String
    public let model: String
    public let reasoningEffort: String?
    public init(provider: String, model: String, reasoningEffort: String? = nil) {
        self.provider = provider; self.model = model; self.reasoningEffort = reasoningEffort
    }
}

public struct DSHModelReasoningEffort: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public init(id: String, name: String, description: String? = nil) {
        self.id = id; self.name = name; self.description = description
    }
}

public struct DSHModelCatalogModel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let reasoning: DSHModelReasoning?
    public init(id: String, name: String, description: String? = nil, reasoning: DSHModelReasoning? = nil) {
        self.id = id; self.name = name; self.description = description; self.reasoning = reasoning
    }
}

public struct DSHModelReasoning: Codable, Sendable, Equatable {
    public let efforts: [DSHModelReasoningEffort]
    public let defaultEffort: String?
    public init(efforts: [DSHModelReasoningEffort], defaultEffort: String? = nil) {
        self.efforts = efforts; self.defaultEffort = defaultEffort
    }
}

public struct DSHModelCatalogGroup: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let models: [DSHModelCatalogModel]
    public init(id: String, name: String, models: [DSHModelCatalogModel]) {
        self.id = id; self.name = name; self.models = models
    }
}

public struct DSHModelCatalogFailure: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let message: String
    public init(id: String, name: String, message: String) {
        self.id = id; self.name = name; self.message = message
    }
}

public struct DSHModelCatalog: Codable, Sendable, Equatable {
    public let `default`: DSHModelSelection
    public let routableProviders: [String]
    public let groups: [DSHModelCatalogGroup]
    public let failures: [DSHModelCatalogFailure]
    public init(default: DSHModelSelection, routableProviders: [String], groups: [DSHModelCatalogGroup], failures: [DSHModelCatalogFailure]) {
        self.default = `default`; self.routableProviders = routableProviders; self.groups = groups; self.failures = failures
    }
}

public enum DSHMessageRole: String, Codable, Sendable { case user, assistant, system, tool }

/// Metadata for a file/image that belongs to a chat message. The bytes are
/// kept in the app's local thumbnail cache; the wire event only carries the
/// receipt/name so a reconnect does not duplicate a large base64 payload.
public struct DSHMessageAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let mediaType: String?
    public let receiptId: String?
    /// Embedded thumbnail (`data:<mime>;base64,…`) for images the phone never
    /// uploaded itself (web uploads, Mac-side files, model-returned images).
    /// Phone uploads keep resolving through the receipt cache instead.
    public let thumbnail: String?

    public init(id: String, name: String, mediaType: String? = nil, receiptId: String? = nil,
                thumbnail: String? = nil) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
        self.receiptId = receiptId
        self.thumbnail = thumbnail
    }

    public var isImage: Bool {
        if mediaType?.lowercased().hasPrefix("image/") == true { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "webp", "gif"].contains(ext)
    }

    /// Thumbnail bytes when the event carried them inline.
    public var thumbnailData: Data? {
        guard let thumbnail else { return nil }
        return dshDataURLBytes(thumbnail)
    }
}

/// Decodes a `data:<mime>;base64,…` URL to bytes. Returns nil for anything
/// else (plain URLs, garbage), so callers can fall through safely.
public func dshDataURLBytes(_ value: String) -> Data? {
    guard let comma = value.firstIndex(of: ",") else { return nil }
    let head = value[value.startIndex..<comma].lowercased()
    guard head.hasPrefix("data:") && head.contains(";base64") else { return nil }
    return Data(base64Encoded: String(value[value.index(after: comma)...]))
}

public struct DSHChatMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let role: DSHMessageRole
    public var markdown: String
    public var attachments: [DSHMessageAttachment]
    public var usage: DSHSessionUsage?
    public var provider: String?
    public var model: String?
    public var reasoningEffort: String?
    public var contextWindow: Double?
    /// Chain-of-thought for this message, kept out of `markdown` so the reply
    /// reads cleanly; the transcript folds it behind a disclosure.
    public var reasoning: String?
    /// Sequence of the event that produced this message. Client-side only.
    public var sequence: Int64?
    /// Wall-clock time the message arrived, in milliseconds since the epoch.
    /// Stamped from the envelope (first sighting wins, like `sequence`) so
    /// the reply timestamp survives replays. Client-side only.
    public var timestamp: Int64?

    public init(id: String, role: DSHMessageRole, markdown: String,
                attachments: [DSHMessageAttachment] = [],
                usage: DSHSessionUsage? = nil, provider: String? = nil, model: String? = nil,
                reasoningEffort: String? = nil, contextWindow: Double? = nil,
                reasoning: String? = nil, sequence: Int64? = nil, timestamp: Int64? = nil) {
        self.id = id; self.role = role; self.markdown = markdown; self.attachments = attachments
        self.usage = usage; self.provider = provider; self.model = model
        self.reasoningEffort = reasoningEffort; self.contextWindow = contextWindow
        self.reasoning = reasoning; self.sequence = sequence; self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, markdown, attachments, usage, provider, model,
             reasoningEffort, contextWindow, reasoning, sequence, timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(DSHMessageRole.self, forKey: .role)
        markdown = try container.decode(String.self, forKey: .markdown)
        // Older Relay/Connector builds did not include this field.
        attachments = try container.decodeIfPresent([DSHMessageAttachment].self,
                                                     forKey: .attachments) ?? []
        usage = try container.decodeIfPresent(DSHSessionUsage.self, forKey: .usage)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        contextWindow = try container.decodeIfPresent(Double.self, forKey: .contextWindow)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        sequence = try container.decodeIfPresent(Int64.self, forKey: .sequence)
        timestamp = try container.decodeIfPresent(Int64.self, forKey: .timestamp)
    }
}

/// One row of the transcript: a single user message, or the consecutive
/// assistant messages that belong to one turn.
///
/// Grouping exists so the reply is what you read: every assistant message of a
/// turn renders as an answer, and all of that turn's chain-of-thought collapses
/// into one disclosure placed after the answers rather than one per message.
public struct DSHTranscriptBlock: Identifiable, Sendable, Equatable {
    public let id: String
    public var messages: [DSHChatMessage]

    public init(id: String, messages: [DSHChatMessage]) {
        self.id = id; self.messages = messages
    }

    public var isUserTurn: Bool { messages.first?.role == .user }

    /// Sequence of the first message, used to interleave with tool calls.
    public var sequence: Int64 { messages.first?.sequence ?? 0 }

    /// Answers in order. An empty markdown only happens when reasoning arrived
    /// before the streamed text, so it must not produce an empty bubble. A
    /// user message can legitimately have no text when it contains only an
    /// image/file; keep those rows so the attachment thumbnail is visible.
    public var visibleMessages: [DSHChatMessage] {
        messages.filter { !$0.markdown.isEmpty || !$0.attachments.isEmpty }
    }

    /// Every reasoning fragment this turn produced, in arrival order.
    public var reasoning: String {
        messages
            .compactMap(\.reasoning)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

public extension Array where Element == DSHChatMessage {
}

public struct DSHPermissionUpdate: Codable, Sendable, Equatable {
    public let sessionId: String
    public let mode: String
    public let approvalPolicy: String?
    public init(sessionId: String, mode: String, approvalPolicy: String? = nil) {
        self.sessionId = sessionId; self.mode = mode; self.approvalPolicy = approvalPolicy
    }
}

public struct DSHUsageUpdate: Codable, Sendable, Equatable {
    public let sessionId: String
    public let usage: DSHSessionUsage
    public init(sessionId: String, usage: DSHSessionUsage) {
        self.sessionId = sessionId; self.usage = usage
    }
}

public struct DSHSessionMetadataUpdate: Codable, Sendable, Equatable {
    public let sessionId: String
    public let provider: String?
    public let model: String?
    public let reasoningEffort: String?
    public let contextWindow: Double?
    public init(sessionId: String, provider: String? = nil, model: String? = nil,
                reasoningEffort: String? = nil, contextWindow: Double? = nil) {
        self.sessionId = sessionId; self.provider = provider; self.model = model
        self.reasoningEffort = reasoningEffort; self.contextWindow = contextWindow
    }
}

/// A compact, inline transcript marker emitted when a session changes model.
/// `sequence` is assigned from the enclosing Relay envelope and never travels
/// over the wire as part of the payload.
public struct DSHModelChangeNotice: Codable, Sendable, Equatable, Identifiable {
    public let sessionId: String
    public let previous: DSHModelSelection?
    public let current: DSHModelSelection
    public var sequence: Int64
    public var timestamp: Int64

    public var id: String {
        "\(sessionId)-\(sequence)-\(current.provider)-\(current.model)"
    }

    public init(sessionId: String, previous: DSHModelSelection? = nil,
                current: DSHModelSelection, sequence: Int64 = 0,
                timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) {
        self.sessionId = sessionId
        self.previous = previous
        self.current = current
        self.sequence = sequence
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey { case sessionId, previous, current, sequence, timestamp }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        previous = try container.decodeIfPresent(DSHModelSelection.self, forKey: .previous)
        current = try container.decode(DSHModelSelection.self, forKey: .current)
        sequence = try container.decodeIfPresent(Int64.self, forKey: .sequence) ?? 0
        timestamp = try container.decodeIfPresent(Int64.self, forKey: .timestamp)
            ?? Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

public struct DSHCommandResult: Codable, Sendable, Equatable, Identifiable {
    public let sessionId: String
    public let requestId: String
    public let matched: Bool
    public let commandId: String?
    public let kind: String?
    public let text: String?
    /// Sequence is assigned by the event reducer from the enclosing event.
    /// The relay payload predates this field, so it remains optional on the
    /// wire while still allowing command acknowledgements to be interleaved
    /// with messages and tool calls in the transcript.
    public var sequence: Int64?
    public var id: String { requestId }
    public init(sessionId: String, requestId: String, matched: Bool,
                commandId: String? = nil, kind: String? = nil, text: String? = nil,
                sequence: Int64? = nil) {
        self.sessionId = sessionId; self.requestId = requestId; self.matched = matched
        self.commandId = commandId; self.kind = kind; self.text = text; self.sequence = sequence
    }
}

public struct DSHUploadedAttachment: Codable, Sendable, Equatable, Identifiable {
    public let sessionId: String
    public let requestId: String
    public let receiptId: String
    public let name: String
    public let mediaType: String?
    public let size: Int?
    public var id: String { receiptId }
    public init(sessionId: String, requestId: String, receiptId: String, name: String,
                mediaType: String? = nil, size: Int? = nil) {
        self.sessionId = sessionId; self.requestId = requestId; self.receiptId = receiptId
        self.name = name; self.mediaType = mediaType; self.size = size
    }
}

public struct DSHAssistantDelta: Codable, Sendable, Equatable {
    public let messageId: String
    public let text: String

    public init(messageId: String, text: String) {
        self.messageId = messageId; self.text = text
    }
}

public struct DSHToolActivity: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public var status: String
    public var detail: String?
    /// The call arguments as they arrived on `tool.started`. A completion
    /// replaces `detail` with the result text, so without this the row title
    /// ("读取 · path") would lose its path the moment the call settles.
    /// Client-side only, optional so older payloads still decode.
    public var arguments: String?
    /// Sequence of the event that produced this call. Client-side only, and
    /// optional so decoding a payload that omits it still works.
    public var sequence: Int64?

    public init(id: String, name: String, status: String = "running", detail: String? = nil,
                arguments: String? = nil, sequence: Int64? = nil) {
        self.id = id; self.name = name; self.status = status; self.detail = detail
        self.arguments = arguments
        self.sequence = sequence
    }
}

/// Web-parity tool row presentation, mirrored from the Harness web client's
/// tool-call row model (`dsh-client-ui-tool`: variant classification, title
/// keys, summary keys). One line — "{verb} · {target}" — keeps the transcript
/// readable while still saying what the model is doing.
public enum DSHToolPresentation {
    /// Row variant per wire tool name; unknown names fall to "others".
    public static func variant(for toolName: String) -> String {
        switch toolName {
        case "bash", "pwsh": return "bash"
        case "read", "read_image", "web_fetch",
             "cordis_package_inspect", "cordis_runtime_inspect": return "read"
        case "web_search", "grep", "glob": return "search"
        case "write": return "write"
        case "edit": return "edit"
        case "run_code": return "code"
        default: return "others"
        }
    }

    /// Chinese verb per tool, exact-name overrides first (as on web).
    public static func title(for toolName: String) -> String {
        switch toolName {
        case "cordis_package_inspect", "cordis_runtime_inspect": return "查看"
        case "cordis_run": return "运行 Cordis 插件"
        case "cordis_stop": return "停止 Cordis 插件"
        case "cordis_undefine": return "移除 Cordis 插件"
        case "pwsh": return "Pwsh"
        case "read_image": return "读取图片"
        default:
            switch variant(for: toolName) {
            case "search": return "搜索"
            case "read": return "读取"
            case "bash": return "Bash"
            case "write": return "写入"
            case "edit": return "编辑"
            case "code": return "代码"
            default: return "工具调用"
            }
        }
    }

    /// First-line target of the call ("docs/IOS-PENDING.md"), picked from the
    /// call arguments per variant, mirroring the web summary keys.
    public static func summary(for toolName: String, arguments: String?) -> String? {
        guard let raw = arguments?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let variant = variant(for: toolName)
        if let object = Self.jsonObject(raw) {
            if variant == "search", let queries = object["queries"] as? [String] {
                let heads = queries.compactMap { Self.firstLine($0) }.filter { !$0.isEmpty }
                if !heads.isEmpty { return heads.joined(separator: ", ") }
            }
            for key in summaryKeys(for: variant) {
                if let value = object[key] as? String,
                   let head = Self.firstLine(value), !head.isEmpty { return head }
            }
            for (_, value) in object {
                if let text = value as? String,
                   let head = Self.firstLine(text), !head.isEmpty { return head }
            }
        }
        return firstLine(raw)
    }

    /// One-line row headline: "读取 · docs/IOS-PENDING.md", verb alone when
    /// the call carries no usable target.
    public static func headline(for tool: DSHToolActivity) -> String {
        let verb = title(for: tool.name)
        if let target = summary(for: tool.name, arguments: tool.arguments ?? tool.detail) {
            return "\(verb) · \(target)"
        }
        return verb
    }

    /// Web status words: 运行中 / 已完成 / 失败 / 已取消.
    public static func statusText(_ status: String) -> String {
        switch status.lowercased() {
        case "running": return "运行中"
        case "succeeded", "success", "completed", "complete": return "已完成"
        case "failed", "error": return "失败"
        case "cancelled", "canceled": return "已取消"
        default: return status
        }
    }

    private static func summaryKeys(for variant: String) -> [String] {
        switch variant {
        case "bash": return ["description", "command"]
        case "read": return ["path", "file_path", "url"]
        case "search": return ["query", "pattern", "url"]
        case "write", "edit": return ["path", "file_path"]
        case "code": return ["description"]
        default: return []
        }
    }

    private static func jsonObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else { return nil }
        return object
    }

    private static func firstLine(_ value: String) -> String? {
        let head = value.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return head.isEmpty ? nil : head
    }
}

public struct DSHApprovalRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionId: String
    public let toolName: String
    public let reason: String
    public let expiresAt: Int64?

    public init(id: String, sessionId: String, toolName: String, reason: String,
                expiresAt: Int64? = nil) {
        self.id = id; self.sessionId = sessionId; self.toolName = toolName
        self.reason = reason; self.expiresAt = expiresAt
    }
}

public struct DSHApprovalResolution: Codable, Sendable, Equatable {
    public let id: String
    public let allowed: Bool

    public init(id: String, allowed: Bool) { self.id = id; self.allowed = allowed }
}

/// One selectable answer for a question raised by `ask_user_question`.
public struct DSHQuestionOption: Codable, Sendable, Equatable, Identifiable {
    public let label: String
    public let description: String?

    public var id: String { label }

    public init(label: String, description: String? = nil) {
        self.label = label; self.description = description
    }
}

public struct DSHQuestion: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let question: String
    public let header: String?
    /// Supporting detail, such as a plan submitted for review.
    public let detail: String?
    public let options: [DSHQuestionOption]?
    public let multiSelect: Bool?

    public init(id: String, question: String, header: String? = nil, detail: String? = nil,
                options: [DSHQuestionOption]? = nil, multiSelect: Bool? = nil) {
        self.id = id; self.question = question; self.header = header; self.detail = detail
        self.options = options; self.multiSelect = multiSelect
    }
}

public struct DSHQuestionRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionId: String
    public let questions: [DSHQuestion]
    public let expiresAt: Int64?

    public init(id: String, sessionId: String, questions: [DSHQuestion], expiresAt: Int64? = nil) {
        self.id = id; self.sessionId = sessionId
        self.questions = questions; self.expiresAt = expiresAt
    }
}

public struct DSHQuestionResolution: Codable, Sendable, Equatable {
    public let id: String
    public let sessionId: String

    public init(id: String, sessionId: String) { self.id = id; self.sessionId = sessionId }
}

public struct DSHReasoning: Codable, Sendable, Equatable {
    public let messageId: String
    public let text: String

    public init(messageId: String, text: String) { self.messageId = messageId; self.text = text }
}

/// An error correlated to the command that caused it.  Connector errors use
/// the command request id as the envelope message id, so the composer can stop
/// waiting immediately instead of reporting a generic attachment timeout.
public struct DSHProtocolError: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

/// Brackets for one history replay batch of a single session, pairing one
/// `history.completed` with its `history.started` when replays overlap.
public struct DSHHistoryBatch: Codable, Sendable, Equatable {
    public let sessionId: String
    public let batchId: String

    public init(sessionId: String, batchId: String) {
        self.sessionId = sessionId
        self.batchId = batchId
    }
}

public struct DSHTurnState: Codable, Sendable, Equatable {
    public let sessionId: String
    public let state: String

    public init(sessionId: String, state: String) { self.sessionId = sessionId; self.state = state }
}

public enum DSHEventKind: Sendable, Equatable {
    /// Phone-to-Relay socket state. This is deliberately separate from Mac
    /// presence: the Relay can remain reachable after the Connector goes away.
    case transportState(DSHConnectionState)
    /// Live Relay presence for the paired Mac Connector.
    case machinePresence(Bool)
    case connectionReady
    case sessionSnapshot([DSHSessionSummary])
    case sessionCreated(DSHSessionSummary)
    case userMessageAccepted(DSHChatMessage)
    case assistantMessageDelta(DSHAssistantDelta)
    case assistantMessageCompleted(DSHChatMessage)
    case toolStarted(DSHToolActivity)
    case toolCompleted(DSHToolActivity)
    case approvalRequested(DSHApprovalRequest)
    case approvalResolved(DSHApprovalResolution)
    case turnStateChanged(DSHTurnState)
    case modelCatalog(DSHModelCatalog)
    case usageUpdated(DSHUsageUpdate)
    case permissionUpdated(DSHPermissionUpdate)
    case sessionMetadataUpdated(DSHSessionMetadataUpdate)
    case modelChanged(DSHModelChangeNotice)
    case commandResult(DSHCommandResult)
    case attachmentUploaded(DSHUploadedAttachment)
    case assistantReasoning(DSHReasoning)
    case questionAsked(DSHQuestionRequest)
    case questionResolved(DSHQuestionResolution)
    case protocolError(DSHProtocolError)
    case historyStarted(DSHHistoryBatch)
    case historyCompleted(DSHHistoryBatch)
    case unknown
}

public struct DSHEvent: Codable, Sendable, Equatable, Identifiable {
    public let envelope: DSHEnvelope
    public let kind: DSHEventKind

    public var id: String { envelope.messageId }
    public var sequence: Int64 { envelope.sequence }
    public var type: String { envelope.type }

    public init(envelope: DSHEnvelope) {
        self.envelope = envelope
        self.kind = DSHEvent.decodeKind(type: envelope.type, payload: envelope.payload)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ payload: DSHJSONValue) -> T? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func decodeKind(type: String, payload: DSHJSONValue) -> DSHEventKind {
        switch type {
        case "transport.state": return decode(DSHConnectionState.self, payload).map(DSHEventKind.transportState) ?? .unknown
        case "machine.presence": return decode(Bool.self, payload).map(DSHEventKind.machinePresence) ?? .unknown
        case "connection.ready": return .connectionReady
        case "session.snapshot": return decode([DSHSessionSummary].self, payload).map(DSHEventKind.sessionSnapshot) ?? .unknown
        case "session.created": return decode(DSHSessionSummary.self, payload).map(DSHEventKind.sessionCreated) ?? .unknown
        case "user.message.accepted": return decode(DSHChatMessage.self, payload).map(DSHEventKind.userMessageAccepted) ?? .unknown
        case "assistant.message.delta": return decode(DSHAssistantDelta.self, payload).map(DSHEventKind.assistantMessageDelta) ?? .unknown
        case "assistant.message.completed": return decode(DSHChatMessage.self, payload).map(DSHEventKind.assistantMessageCompleted) ?? .unknown
        case "tool.started": return decode(DSHToolActivity.self, payload).map(DSHEventKind.toolStarted) ?? .unknown
        case "tool.completed": return decode(DSHToolActivity.self, payload).map(DSHEventKind.toolCompleted) ?? .unknown
        case "approval.requested": return decode(DSHApprovalRequest.self, payload).map(DSHEventKind.approvalRequested) ?? .unknown
        case "approval.resolved": return decode(DSHApprovalResolution.self, payload).map(DSHEventKind.approvalResolved) ?? .unknown
        case "turn.state.changed": return decode(DSHTurnState.self, payload).map(DSHEventKind.turnStateChanged) ?? .unknown
        case "model.catalog": return decode(DSHModelCatalog.self, payload).map(DSHEventKind.modelCatalog) ?? .unknown
        case "usage.updated": return decode(DSHUsageUpdate.self, payload).map(DSHEventKind.usageUpdated) ?? .unknown
        case "permission.updated": return decode(DSHPermissionUpdate.self, payload).map(DSHEventKind.permissionUpdated) ?? .unknown
        case "session.metadata.updated": return decode(DSHSessionMetadataUpdate.self, payload).map(DSHEventKind.sessionMetadataUpdated) ?? .unknown
        case "session.model.changed": return decode(DSHModelChangeNotice.self, payload).map(DSHEventKind.modelChanged) ?? .unknown
        case "command.result": return decode(DSHCommandResult.self, payload).map(DSHEventKind.commandResult) ?? .unknown
        case "attachment.uploaded": return decode(DSHUploadedAttachment.self, payload).map(DSHEventKind.attachmentUploaded) ?? .unknown
        case "assistant.reasoning": return decode(DSHReasoning.self, payload).map(DSHEventKind.assistantReasoning) ?? .unknown
        case "question.asked": return decode(DSHQuestionRequest.self, payload).map(DSHEventKind.questionAsked) ?? .unknown
        case "question.resolved": return decode(DSHQuestionResolution.self, payload).map(DSHEventKind.questionResolved) ?? .unknown
        case "protocol.error": return decode(DSHProtocolError.self, payload).map(DSHEventKind.protocolError) ?? .unknown
        case "history.started": return decode(DSHHistoryBatch.self, payload).map(DSHEventKind.historyStarted) ?? .unknown
        case "history.completed": return decode(DSHHistoryBatch.self, payload).map(DSHEventKind.historyCompleted) ?? .unknown
        default: return .unknown
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(envelope: try DSHEnvelope(from: decoder))
    }

    public func encode(to encoder: Encoder) throws { try envelope.encode(to: encoder) }
}

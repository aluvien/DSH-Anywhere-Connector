import Foundation

public struct DSHWorkspaceFiles: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public let name: String
        public let type: String
        public let size: Int?
        public var id: String { name }
    }
    public let sessionId: String
    public let path: String
    public let truncated: Bool
    public let entries: [Entry]
}

public struct DSHWorkspaceBytes: Codable, Equatable, Sendable {
    public let sessionId: String
    public let absolutePath: String
    public let version: String
    public let bytes: Int?
    public let offset: Int
    public let data: String
    public let eof: Bool
}

/// Keep the native Session scope; web links are a separate operation.
public struct DSHFileReference: Identifiable, Equatable, Sendable {
    public let sessionID: String
    public let path: String
    public let displayName: String?
    public var id: String { "\(sessionID.utf8.count):\(sessionID)\(path)" }
    public var name: String { displayName ?? (path as NSString).lastPathComponent }

    public init(sessionID: String, path: String, name: String? = nil) { self.sessionID = sessionID; self.path = path; self.displayName = name }

    public init?(url: URL, sessionID: String) {
        self.displayName = nil
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let scheme = parts.scheme?.lowercased()
        if scheme == "dsh-resource", parts.host == "file" {
            let encoded = parts.percentEncodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            guard encoded.count >= 2 else { return nil }
            if encoded[0] == "session", encoded.count >= 3, let scope = String(encoded[1]).removingPercentEncoding, !scope.isEmpty {
                self.sessionID = scope
                let segments = encoded.dropFirst(2).map { String($0).removingPercentEncoding }
                guard segments.allSatisfy({ $0 != nil }) else { return nil }
                self.path = segments.compactMap { $0 }.joined(separator: "/")
            } else if encoded[0] == "absolute" {
                self.sessionID = sessionID
                let unc = encoded.count > 2 && encoded[1].isEmpty
                let segments = encoded.dropFirst(unc ? 2 : 1).map { String($0).removingPercentEncoding }
                guard segments.allSatisfy({ $0 != nil }), let first = segments.first ?? nil, !first.isEmpty else { return nil }
                let decoded = segments.compactMap { $0 }.joined(separator: "/")
                let drive = first.range(of: "^[A-Za-z]:$", options: .regularExpression) != nil
                self.path = unc ? "//" + decoded : drive ? decoded : "/" + decoded
            } else { return nil }
        } else if scheme == "file", parts.host == nil || parts.host == "" || parts.host == "localhost" {
            self.sessionID = sessionID; self.path = parts.path
        } else if scheme == nil, parts.host == nil, !parts.path.isEmpty {
            self.sessionID = sessionID; self.path = parts.path
        } else { return nil }
        guard !path.isEmpty, !path.contains("\0") else { return nil }
    }

    public static func links(in markdown: String, sessionID: String) -> [DSHFileReference] {
        guard let attributed = try? AttributedString(markdown: markdown) else { return [] }
        var seen: Set<String> = []
        return attributed.runs.compactMap { run in
            guard let url = run.link, let reference = DSHFileReference(url: url, sessionID: sessionID),
                  seen.insert(reference.id).inserted else { return nil }
            return reference
        }
    }
}

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
    /// Identifies events emitted as part of one history replay batch. Live
    /// events leave this nil so a late replay row cannot settle local work.
    public let historyBatchId: String?
    public let sequence: Int64
    /// Milliseconds since Unix epoch, as used by the JavaScript side.
    public let timestamp: Int64
    public let type: String
    public let payload: DSHJSONValue

    public init(version: Int = 1, messageId: String, deviceId: String,
                machineId: String, sessionId: String? = nil,
                historyBatchId: String? = nil,
                sequence: Int64, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
                type: String, payload: DSHJSONValue = .object([:])) {
        self.version = version
        self.messageId = messageId
        self.deviceId = deviceId
        self.machineId = machineId
        self.sessionId = sessionId
        self.historyBatchId = historyBatchId
        self.sequence = sequence
        self.timestamp = timestamp
        self.type = type
        self.payload = payload
    }

    // The relay protocol uses optional fields, not JSON nulls.  Swift's
    // synthesized Codable implementation emits `sessionId: null`, which is
    // rejected by the relay's strict object schemas.
    private enum CodingKeys: String, CodingKey {
        case version, messageId, deviceId, machineId, sessionId, historyBatchId, sequence, timestamp, type, payload
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(messageId, forKey: .messageId)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(machineId, forKey: .machineId)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(historyBatchId, forKey: .historyBatchId)
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

    public static func resume(deviceId: String, machineId: String, lastSequence: Int64,
                              includeArchived: Bool) -> DSHCommand {
        DSHCommand(deviceId: deviceId, machineId: machineId, type: "connection.resume",
                   payload: .object(["lastSequence": .number(Double(lastSequence)),
                                     "includeArchived": .bool(includeArchived)]))
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
                                    includeArchived: Bool = false,
                                    requestId: String = UUID().uuidString) -> DSHCommand {
        DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId, type: "session.list",
                   payload: .object(["includeArchived": .bool(includeArchived)]))
    }

    /// Requests the durable transcript for one existing session. The Connector
    /// asks the Mac bridge to inspect that session and forwards the normalized
    /// history as ordinary transcript events over the existing socket.
    public static func openSession(deviceId: String, machineId: String,
                                   sessionId: String, streaming: Bool = false,
                                   parentSessionId: String? = nil, subagentMode: String? = nil,
                                   requestId: String = UUID().uuidString) -> DSHCommand {
        var payload: [String: DSHJSONValue] = ["sessionId": .string(sessionId)]
        if streaming { payload["streaming"] = .bool(true) }
        if let parentSessionId { payload["parentSessionId"] = .string(parentSessionId) }
        if let subagentMode { payload["subagentMode"] = .string(subagentMode) }
        return DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                   sessionId: sessionId, type: "session.open",
                   payload: .object(payload))
    }

    public static func archiveSession(deviceId: String, machineId: String, sessionId: String,
                                      archived: Bool, requestId: String = UUID().uuidString) -> DSHCommand {
        DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                   sessionId: sessionId, type: "session.archive",
                   payload: .object(["archived": .bool(archived)]))
    }

    public static func renameSession(deviceId: String, machineId: String, sessionId: String,
                                     title: String, requestId: String = UUID().uuidString) -> DSHCommand {
        DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                   sessionId: sessionId, type: "session.rename",
                   payload: .object(["title": .string(title)]))
    }

    public static func directoryList(deviceId: String, machineId: String, path: String? = nil,
                                     requestId: String = UUID().uuidString) -> DSHCommand {
        var payload: [String: DSHJSONValue] = [:]
        if let path, !path.isEmpty { payload["path"] = .string(path) }
        return DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                          type: "directory.list", payload: .object(payload))
    }

    public static func workspaceCatalog(deviceId: String, machineId: String,
                                        requestId: String = UUID().uuidString) -> DSHCommand {
        DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                   type: "workspace.catalog", payload: .object([:]))
    }

    public static func createWorkspace(deviceId: String, machineId: String, path: String,
                                       title: String? = nil,
                                       requestId: String = UUID().uuidString) -> DSHCommand {
        var payload: [String: DSHJSONValue] = ["path": .string(path)]
        if let title, !title.isEmpty { payload["title"] = .string(title) }
        return DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                          type: "workspace.create", payload: .object(payload))
    }

    public static func modeCatalog(deviceId: String, machineId: String,
                                   requestId: String = UUID().uuidString) -> DSHCommand {
        DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                   type: "mode.catalog", payload: .object([:]))
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

    public static func forkSession(deviceId: String, machineId: String, sessionId: String,
                                   atSeq: Int64? = nil, requestId: String = UUID().uuidString) -> DSHCommand {
        var payload: [String: DSHJSONValue] = [:]
        if let atSeq { payload["atSeq"] = .number(Double(atSeq)) }
        return DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                          sessionId: sessionId, type: "session.fork", payload: .object(payload))
    }
    public static func commandCatalog(deviceId: String, machineId: String, sessionId: String) -> DSHCommand {
        DSHCommand(deviceId: deviceId, machineId: machineId, sessionId: sessionId,
                   type: "command.catalog", payload: .object([:]))
    }
    public static func subagentCatalog(deviceId: String, machineId: String, sessionId: String) -> DSHCommand {
        DSHCommand(deviceId: deviceId, machineId: machineId, sessionId: sessionId,
                   type: "subagent.catalog", payload: .object([:]))
    }
    public static func workspaceFiles(deviceId: String, machineId: String, sessionId: String, path: String) -> DSHCommand {
        DSHCommand(deviceId: deviceId, machineId: machineId, sessionId: sessionId,
                   type: "workspace.files", payload: .object(["path": .string(path)]))
    }
    public static func executionList(deviceId: String, machineId: String, sessionId: String, beforeSeq: Int64? = nil,
                                      parentSessionId: String? = nil, subagentMode: String? = nil) -> DSHCommand {
        var payload: [String: DSHJSONValue] = ["limit": .number(100)]
        if let beforeSeq { payload["beforeSeq"] = .number(Double(beforeSeq)) }
        if let parentSessionId { payload["parentSessionId"] = .string(parentSessionId) }
        if let subagentMode { payload["subagentMode"] = .string(subagentMode) }
        return DSHCommand(deviceId: deviceId, machineId: machineId, sessionId: sessionId, type: "execution.list", payload: .object(payload))
    }
    public static func workspaceBytes(deviceId: String, machineId: String, sessionId: String, path: String,
                                      offset: Int, version: String? = nil) -> DSHCommand {
        var payload: [String: DSHJSONValue] = ["path": .string(path), "offset": .number(Double(offset)), "length": .number(192 * 1_024)]
        if let version { payload["version"] = .string(version) }
        return DSHCommand(deviceId: deviceId, machineId: machineId, sessionId: sessionId,
                          type: "workspace.bytes", payload: .object(payload))
    }
    public static func controlSubagent(deviceId: String, machineId: String, childID: String, parentID: String,
                                        text: String? = nil, delivery: String = "queue", images: [DSHJSONValue] = []) -> DSHCommand {
        var payload: [String: DSHJSONValue] = ["parentSessionId": .string(parentID), "mode": .string("continuable")]
        if let text {
            payload["text"] = .string(text)
            payload["delivery"] = .string(delivery)
            payload["clientTimeZone"] = .string(TimeZone.current.identifier)
            if !images.isEmpty { payload["images"] = .array(images) }
        }
        return DSHCommand(deviceId: deviceId, machineId: machineId, sessionId: childID,
                          type: text == nil ? "subagent.interrupt" : "subagent.prompt", payload: .object(payload))
    }
    public static func updateQueue(deviceId: String, machineId: String, sessionId: String,
                                   itemId: String, action: String, text: String? = nil) -> DSHCommand {
        var payload: [String: DSHJSONValue] = ["itemId": .string(itemId), "action": .string(action)]
        if let text { payload["text"] = .string(text) }
        return DSHCommand(deviceId: deviceId, machineId: machineId, sessionId: sessionId,
                          type: "queue.update", payload: .object(payload))
    }
    public static func getGoal(deviceId: String, machineId: String, sessionId: String) -> DSHCommand {
        DSHCommand(deviceId: deviceId, machineId: machineId, sessionId: sessionId, type: "goal.get", payload: .object([:]))
    }
    public static func updateGoal(deviceId: String, machineId: String, sessionId: String, goal: DSHGoalState.Goal,
                                  action: String, objective: String? = nil, maxGoalRounds: Int? = nil) -> DSHCommand {
        var payload: [String: DSHJSONValue] = ["action": .string(action),
            "ref": .object(["id": .string(goal.id), "revision": .number(Double(goal.revision))])]
        if let objective { payload["objective"] = .string(objective) }
        if let maxGoalRounds { payload["maxGoalRounds"] = .number(Double(maxGoalRounds)) }
        return DSHCommand(deviceId: deviceId, machineId: machineId, sessionId: sessionId, type: "goal.update", payload: .object(payload))
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
    public static func cancelQuestion(deviceId: String, machineId: String, sessionId: String,
                                     questionId: String) -> DSHCommand {
        DSHCommand(deviceId: deviceId, machineId: machineId, sessionId: sessionId,
                   type: "question.cancel", payload: .object(["questionId": .string(questionId)]))
    }

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
    case historyGap(DSHHistoryRange)
    case message(DSHChatMessage)
    case tool(DSHToolActivity)
    case command(DSHCommandResult)
    case modelChange(DSHModelChangeNotice)
    case workflow(DSHWorkflowRun)
    case execution(DSHExecutionNotice)

    var sequence: Int64 {
        switch self {
        case .historyGap: return 0
        case .message(let message): return message.sequence ?? 0
        case .tool(let tool): return tool.sequence ?? 0
        case .command(let result): return result.sequence ?? 0
        case .modelChange(let notice): return notice.sequence
        case .workflow(let run): return run.sequence ?? 0
        case .execution(let notice): return notice.sequence ?? 0
        }
    }

    var nativeSequence: Int64? {
        switch self {
        case .historyGap(let range): return range.upper
        case .message(let message): return message.nativeSequence
        case .tool(let tool): return tool.nativeSequence
        case .command(let command): return command.nativeSequence
        case .modelChange(let change): return change.nativeSequence
        case .workflow(let run): return run.nativeSequence
        case .execution(let notice): return notice.nativeSequence
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
    case historyGap(DSHHistoryRange)
    case turn(DSHTranscriptBlock)
    case tool(DSHToolActivity)
    case command(DSHCommandResult)
    case modelChange(DSHModelChangeNotice)
    case workflow(DSHWorkflowRun)
    case execution(DSHExecutionNotice)

    public var id: String {
        switch self {
        case .historyGap(let range): return "history-gap-\(range.id)"
        case .turn(let block): return "turn-\(block.id)"
        case .tool(let tool): return "tool-\(tool.id)"
        case .command(let result): return "command-\(result.id)"
        case .modelChange(let notice): return "model-change-\(notice.id)"
        case .workflow(let run): return "workflow-\(run.id)"
        case .execution(let notice): return "execution-\(notice.id)"
        }
    }

    var sequence: Int64 {
        switch self {
        case .historyGap: return 0
        case .turn(let block): return block.sequence
        case .tool(let tool): return tool.sequence ?? 0
        case .command(let result): return result.sequence ?? 0
        case .modelChange(let notice): return notice.sequence
        case .workflow(let run): return run.sequence ?? 0
        case .execution(let notice): return notice.sequence ?? 0
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
                           modelChanges: [DSHModelChangeNotice] = [],
                           workflows: [DSHWorkflowRun] = [],
                           execution: [DSHExecutionNotice] = [], historyGaps: [DSHHistoryRange] = []) -> [DSHTranscriptEntry] {
        // Stable by construction: a tie keeps arrival order. Sorting on the
        // sequence alone is not enough, because state persisted before
        // sequences existed carries none, and any arbitrary tie-break (id
        // order, say) would scramble the whole transcript on upgrade.
        var ordered: [(order: Int, arrival: DSHTranscriptArrival)] = []
        for gap in historyGaps { ordered.append((ordered.count, .historyGap(gap))) }
        for message in self { ordered.append((ordered.count, .message(message))) }
        for tool in tools { ordered.append((ordered.count, .tool(tool))) }
        for result in commandResults { ordered.append((ordered.count, .command(result))) }
        for notice in modelChanges { ordered.append((ordered.count, .modelChange(notice))) }
        for run in workflows where run.sequence != nil { ordered.append((ordered.count, .workflow(run))) }
        for notice in execution where notice.sequence != nil { ordered.append((ordered.count, .execution(notice))) }
        ordered.sort { left, right in
            left.arrival.sequence == right.arrival.sequence
                ? left.order < right.order
                : left.arrival.sequence < right.arrival.sequence
        }
        // A replay can add native records beside cached rows whose first
        // Relay positions belong to an earlier Connector process. Use native
        // positions where available; retain legacy/transient rows between
        // their neighbouring known anchors without a non-transitive mixed
        // Native-vs-Relay comparator.
        var positions = ordered.map { $0.arrival.nativeSequence.map(Double.init) }
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
                else { positions[offset] = Double(ordered[offset].arrival.sequence) }
            }
        }
        ordered = ordered.enumerated().sorted { left, right in
            let a = positions[left.offset] ?? 0, b = positions[right.offset] ?? 0
            return a == b ? left.offset < right.offset : a < b
        }.map(\.element)
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
            case .historyGap(let range):
                flushRun()
                entries.append(.historyGap(range))
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
            case .workflow(let workflow):
                flushRun()
                entries.append(.workflow(workflow))
            case .execution(let notice):
                flushRun()
                entries.append(.execution(notice))
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
    /// Commands and model notices stay in place. A new user message closes
    /// the task, so cancelled reasoning cannot leak into the next task's
    /// disclosure or elapsed time.
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
            case .row(.turn(let block)) where block.isUserTurn:
                flushPendingAsOwnSection()
                merged.append(section)
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
    /// Correlates an authoritative snapshot with a detached create request.
    public var createRequestId: String?
    public var usage: DSHSessionUsage?

    public init(id: String, title: String = "", updatedAt: Int64 = 0,
                cwd: String? = nil, workspaceId: String? = nil, workspaceName: String? = nil,
                archived: Bool? = nil, running: Bool? = nil, blank: Bool? = nil,
                parentSessionId: String? = nil, provider: String? = nil, model: String? = nil,
                reasoningEffort: String? = nil, permissionMode: String? = nil,
                agentPreset: String? = nil, mode: String? = nil, branch: String? = nil,
                createRequestId: String? = nil,
                usage: DSHSessionUsage? = nil) {
        self.id = id; self.title = title; self.updatedAt = updatedAt
        self.cwd = cwd; self.workspaceId = workspaceId; self.workspaceName = workspaceName
        self.archived = archived; self.running = running; self.blank = blank
        self.parentSessionId = parentSessionId; self.agentPreset = agentPreset; self.mode = mode; self.branch = branch
        self.provider = provider; self.model = model
        self.reasoningEffort = reasoningEffort; self.permissionMode = permissionMode
        self.createRequestId = createRequestId; self.usage = usage
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
    public let hostPath: String?

    public init(id: String, name: String, mediaType: String? = nil, receiptId: String? = nil,
                thumbnail: String? = nil, hostPath: String? = nil) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
        self.receiptId = receiptId
        self.thumbnail = thumbnail
        self.hostPath = hostPath
    }

    public func fileReference(sessionID: String) -> DSHFileReference? {
        guard let hostPath, !hostPath.isEmpty else { return nil }
        var filename = name
        if (filename as NSString).pathExtension.isEmpty {
            let suffix = ["image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif"][mediaType ?? ""]
            if let suffix { filename += "." + suffix }
        }
        return DSHFileReference(sessionID: sessionID, path: hostPath, name: filename)
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
    public var replacesMessageId: String?
    public var interrupted: Bool?
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
    public var nativeSequence: Int64?
    /// Stamped from the envelope (first sighting wins, like `sequence`) so
    /// the reply timestamp survives replays. Client-side only.
    public var timestamp: Int64?
    /// Live completion times, preserved through replay. History envelope
    /// timestamps describe delivery, so they must never populate these.
    public var completedAt: Int64?
    public var taskCompletedAt: Int64?

    public init(id: String, role: DSHMessageRole, markdown: String,
                attachments: [DSHMessageAttachment] = [],
                usage: DSHSessionUsage? = nil, provider: String? = nil, model: String? = nil,
                reasoningEffort: String? = nil, contextWindow: Double? = nil,
                reasoning: String? = nil, sequence: Int64? = nil, timestamp: Int64? = nil,
                replacesMessageId: String? = nil, nativeSequence: Int64? = nil, interrupted: Bool? = nil) {
        self.id = id; self.role = role; self.markdown = markdown; self.attachments = attachments
        self.usage = usage; self.provider = provider; self.model = model
        self.reasoningEffort = reasoningEffort; self.contextWindow = contextWindow
        self.reasoning = reasoning; self.sequence = sequence; self.timestamp = timestamp
        self.replacesMessageId = replacesMessageId
        self.nativeSequence = nativeSequence
        self.interrupted = interrupted
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, markdown, attachments, usage, provider, model, replacesMessageId,
             reasoningEffort, contextWindow, reasoning, sequence, timestamp, completedAt, taskCompletedAt, nativeSequence, interrupted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        replacesMessageId = try container.decodeIfPresent(String.self, forKey: .replacesMessageId)
        nativeSequence = try container.decodeIfPresent(Int64.self, forKey: .nativeSequence)
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
        completedAt = try container.decodeIfPresent(Int64.self, forKey: .completedAt)
        taskCompletedAt = try container.decodeIfPresent(Int64.self, forKey: .taskCompletedAt)
        nativeSequence = try container.decodeIfPresent(Int64.self, forKey: .nativeSequence)
        replacesMessageId = try container.decodeIfPresent(String.self, forKey: .replacesMessageId)
        interrupted = try container.decodeIfPresent(Bool.self, forKey: .interrupted)
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
    /// Assigned only to the first rendered assistant section of a user task.
    public var taskTimeline: DSHTaskTimeline?

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

public struct DSHTaskTimeline: Sendable, Equatable {
    public let promptID: String?
    public let startedAt: Int64?
    public let messages: [DSHChatMessage]
    public let tools: [DSHToolActivity]

    public var reasoning: String {
        messages.compactMap(\.reasoning).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Historical records without live timing can only estimate generation
    /// time. Do not treat replay delivery times or input-token processing as
    /// elapsed task time; include every available step, not just the last one.
    public func duration(now: Date? = nil) -> (seconds: Int, estimated: Bool)? {
        let end = now.map { Int64($0.timeIntervalSince1970 * 1_000) }
            ?? messages.compactMap(\.taskCompletedAt).max()
            ?? messages.compactMap(\.completedAt).max()
        if let start = startedAt, start > 0, let end, end >= start {
            return (Int((end - start) / 1_000), false)
        }
        let estimates = messages.compactMap { message -> Double? in
            guard let usage = message.usage, let speed = usage.tokensPerSecond,
                  speed.isFinite, speed > 0, let tokens = usage.outputTokens,
                  tokens.isFinite, tokens > 0 else { return nil }
            return tokens / speed
        }
        let total = estimates.reduce(0, +)
        guard !estimates.isEmpty, total.isFinite, total < Double(Int.max) else { return nil }
        return (max(1, Int(total.rounded())), true)
    }
}

public extension Array where Element == DSHTranscriptSection {
    /// Preserve message/command order and section IDs. Only the first answer
    /// owns a header, which discloses all reasoning and tools for that task.
    func withTaskTimelines() -> [DSHTranscriptSection] {
        var result = self
        var prompt: DSHChatMessage?
        var indices: [Int] = []
        func flush() {
            guard !indices.isEmpty else { return }
            let blocks = indices.compactMap { index -> DSHTranscriptBlock? in
                if case .turn(let block, _) = result[index] { return block }
                return nil
            }
            let messages = blocks.flatMap(\.messages)
            let tools = indices.flatMap { index -> [DSHToolActivity] in
                if case .turn(_, let tools) = result[index] { return tools }
                return []
            }
            // A reasoning-only section can be hidden while streaming. Anchor
            // to the first visible answer when there is one.
            let headerIndex = indices.first { index in
                if case .turn(let block, _) = result[index] { return !block.visibleMessages.isEmpty }
                return false
            } ?? indices[0]
            if case .turn(var block, let ownTools) = result[headerIndex] {
                block.taskTimeline = DSHTaskTimeline(promptID: prompt?.id,
                    startedAt: prompt?.timestamp ?? messages.first?.timestamp,
                    messages: messages, tools: tools)
                result[headerIndex] = .turn(block: block, tools: ownTools)
            }
            indices = []
        }
        for index in result.indices {
            switch result[index] {
            case .row(.historyGap):
                flush()
                prompt = nil
            case .row(.turn(let block)) where block.isUserTurn:
                flush()
                prompt = block.messages.first
            case .turn(let block, _) where !block.isUserTurn:
                indices.append(index)
            default: break
            }
        }
        flush()
        return result
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
    public var nativeSequence: Int64?

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

    private enum CodingKeys: String, CodingKey { case sessionId, previous, current, sequence, timestamp, nativeSequence }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        previous = try container.decodeIfPresent(DSHModelSelection.self, forKey: .previous)
        current = try container.decode(DSHModelSelection.self, forKey: .current)
        sequence = try container.decodeIfPresent(Int64.self, forKey: .sequence) ?? 0
        nativeSequence = try container.decodeIfPresent(Int64.self, forKey: .nativeSequence)
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
    public var nativeSequence: Int64?
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

/// A request-scoped receipt that the Harness accepted a prompt.  It is kept
/// separate from the durable user-message event because that transcript event
/// can be broadcast or replayed from history and therefore cannot identify the
/// phone request by itself.
public struct DSHPromptAccepted: Codable, Sendable, Equatable {
    public let sessionId: String
    public let requestId: String

    public init(sessionId: String, requestId: String) {
        self.sessionId = sessionId
        self.requestId = requestId
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
    public var nativeSequence: Int64?
    public var rootCallId: String?
    public var parentCallId: String?
    public var startedAt: Double?
    public var finishedAt: Double?
    public var resultMeta: DSHJSONValue?
    public var resultContent: [DSHJSONValue]?
    public var error: DSHJSONValue?
    public var attachments: [DSHMessageAttachment]?
    /// Derived locally from native parent identities; never inferred from names.
    public var children: [DSHToolActivity]?

    public init(id: String, name: String, status: String = "running", detail: String? = nil,
                arguments: String? = nil, sequence: Int64? = nil) {
        self.id = id; self.name = name; self.status = status; self.detail = detail
        self.arguments = arguments
        self.sequence = sequence
    }
}

public struct DSHFeedbackItem: Codable, Sendable, Equatable, Identifiable {
    public let messageId: String
    public let rating: String
    public let note: String?
    public let category: String?
    public let version: String
    public let createdAt: Double
    public let updatedAt: Double
    public var id: String { messageId }
}
public struct DSHFeedbackState: Codable, Sendable, Equatable {
    public let sessionId: String
    public var items: [DSHFeedbackItem]
    public var nativeSequence: Int64
}
public struct DSHFeedbackChange: Codable, Sendable, Equatable {
    public let sessionId: String
    public let messageId: String
    public let item: DSHFeedbackItem?
    public let nativeSequence: Int64
}
public struct DSHFeedbackReceipt: Codable, Sendable, Equatable {
    public let sessionId: String
    public let messageId: String
    public let requestId: String
    public let item: DSHFeedbackItem?
}
public struct DSHReferenceCandidates: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let kind: String
        public let insertion: String
        public let path: String?
        public let sourceSessionId: String?
        public let detail: String?
        public let sameWorkspace: Bool?
    }
    public let sessionId: String
    public let kind: String
    public let query: String
    public let items: [Item]
}

public enum DSHSessionReference {
    /// Native URI is base64url(JSON.stringify(opaque sessionId)), not a path.
    public static func sessionID(from url: URL) -> String? {
        let text = url.absoluteString, prefix = "dsh-session:"
        guard text.hasPrefix(prefix) else { return nil }
        let payload = String(text.dropFirst(prefix.count))
        guard !payload.isEmpty, payload.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)),
              let id = try? JSONDecoder().decode(String.self, from: data), !id.isEmpty else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let canonical = try? encoder.encode(id),
              canonical.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == payload else { return nil }
        return id
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

public struct DSHDecisionVersion: Codable, Sendable, Equatable {
    public let epoch: String
    public let revision: Int64
}
public struct DSHDecisionsSnapshot: Codable, Sendable, Equatable {
    public let stateVersion: DSHDecisionVersion
    public let approvals: [DSHApprovalRequest]
    public let questions: [DSHQuestionRequest]
}
public struct DSHApprovalRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionId: String
    public let toolName: String
    public let reason: String
    public let expiresAt: Int64?

    public init(id: String, sessionId: String, toolName: String, reason: String,
                expiresAt: Int64? = nil, stateVersion: DSHDecisionVersion? = nil) {
        self.id = id; self.sessionId = sessionId; self.toolName = toolName
        self.reason = reason; self.expiresAt = expiresAt
        self.stateVersion = stateVersion
    }
    public let stateVersion: DSHDecisionVersion?
}

public struct DSHApprovalResolution: Codable, Sendable, Equatable {
    public let id: String
    public let allowed: Bool

    public let stateVersion: DSHDecisionVersion?
    public init(id: String, allowed: Bool, stateVersion: DSHDecisionVersion? = nil) {
        self.id = id; self.allowed = allowed; self.stateVersion = stateVersion
    }
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

public struct DSHWorkflowRun: Codable, Sendable, Equatable, Identifiable {
    public struct Member: Codable, Sendable, Equatable, Identifiable {
        public let seq: Int
        public let label: String
        public let phase: String?
        public let childId: String
        public let status: String
        public var id: Int { seq }
    }
    public struct Phase: Sendable, Equatable, Identifiable {
        public let name: String?
        public var members: [Member]
        public var id: String { name.map { "value:\($0.utf16.count):\($0)" } ?? "missing" }
    }
    public let id: String
    public let name: String
    public let status: String
    public let nativeSequence: Int64?
    public let updatedNativeSequence: Int64?
    public let startedAt: Int64?
    public let finishedAt: Int64?
    public let members: [Member]
    public var sequence: Int64?
    public var phases: [Phase] {
        var result: [Phase] = []
        for member in members {
            if let index = result.firstIndex(where: { $0.name == member.phase }) { result[index].members.append(member) }
            else { result.append(Phase(name: member.phase, members: [member])) }
        }
        return result
    }
}
public struct DSHWorkflowChanged: Codable, Sendable, Equatable {
    public let sessionId: String
    public let run: DSHWorkflowRun
    public let inTranscript: Bool?
}

public struct DSHPlanState: Codable, Sendable, Equatable {
    public let sessionId: String
    public let active: Bool
    public var pending: Bool? = nil
    public var available: Bool? = nil
}

public struct DSHPlanProjection: Codable, Sendable, Equatable {
    public let sessionId: String
    public let active: Bool
    public let pending: Bool
    public var available: Bool
    public let supported: Bool
    public let epoch: String
    public let seq: Int64
}

public struct DSHCommandCatalog: Codable, Sendable, Equatable {
    public struct Skill: Codable, Sendable, Equatable {
        public let name: String
        public let description: String
        public let whenToUse: String?
        public let modelInvocable: Bool
    }
    public struct Entry: Codable, Sendable, Equatable {
        public struct Input: Codable, Sendable, Equatable {
            public let hint: String
            public let attachments: Bool?
        }
        public let name: String
        public let description: String
        public let input: Input?
    }
    public let sessionId: String
    public let supported: Bool?
    public let commands: [Entry]
    public let skills: [Skill]?
}

public struct DSHCommandCatalogInvalidated: Codable, Sendable, Equatable {
    public let sessionId: String?
}

public struct DSHSessionForked: Codable, Sendable, Equatable {
    public let sessionId: String
    public let parentSessionId: String
    public let requestId: String
}

public struct DSHTodoState: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public let content: String
        public let status: String
    }
    public let sessionId: String
    public let todos: [Item]
}

public struct DSHJobsState: Codable, Sendable, Equatable {
    public struct Job: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let kind: String
        public let label: String
        public let status: String
        public let detail: String?
        public let startedAt: Int64
        public let finishedAt: Int64?
    }
    public let sessionId: String
    public let available: Bool
    public let jobs: [Job]
}

public struct DSHServerQueue: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public struct Message: Codable, Sendable, Equatable {
            public let id: String
            public let content: [DSHJSONValue]
        }
        public let id: String
        public let placement: String
        public let rpcId: String?
        public let message: Message
        public let attachments: [DSHMessageAttachment]?
        public init(id: String, placement: String, rpcId: String? = nil, message: Message, attachments: [DSHMessageAttachment]? = nil) {
            self.id = id; self.placement = placement; self.rpcId = rpcId; self.message = message; self.attachments = attachments
        }
        public var text: String {
            message.content.compactMap { block -> String? in
                guard case .object(let fields) = block, fields["type"] == .string("text"),
                      case .string(let text) = fields["text"] else { return nil }
                return text
            }.joined(separator: "\n")
        }
        public var isTextOnly: Bool {
            !message.content.isEmpty && message.content.allSatisfy { block in
                if case .object(let fields) = block { return fields["type"] == .string("text") }
                return false
            }
        }
    }
    public let sessionId: String
    public let available: Bool
    public let items: [Item]
}

public struct DSHQueueUpdated: Codable, Sendable, Equatable {
    public let sessionId: String
    public let itemId: String
    public let requestId: String
}

public struct DSHSubagentCatalog: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public let kind: String
        public let id: String
        public let activity: String?
        public let hasChildren: Bool?
        public let mode: String?
        public let label: String?
        public let reason: String?
    }
    public let parentSessionId: String
    public let parentAvailable: Bool
    public let supported: Bool?
    public let entries: [Entry]
}

public struct DSHSubagentCatalogInvalidated: Codable, Sendable, Equatable {
    public let parentSessionId: String
}

public struct DSHSubagentReceipt: Codable, Sendable, Equatable {
    public let parentSessionId: String
    public let childSessionId: String
    public let requestId: String
    public let action: String
    public let messageId: String?
}

public struct DSHGoalState: Codable, Sendable, Equatable {
    public struct Goal: Codable, Sendable, Equatable, Identifiable {
        public struct BlockReason: Codable, Sendable, Equatable {
            public let code: String
            public let message: String
        }
        public let id: String
        public let revision: Int
        public let objective: String
        public let phase: String
        public let maxGoalRounds: Int
        public let blockedReason: BlockReason?
    }
    public let sessionId: String
    public let goal: Goal?
    public var roundsStarted: Int
    public var activation: String?
}

public struct DSHGoalUpdated: Codable, Sendable, Equatable {
    public struct Ref: Codable, Sendable, Equatable {
        public let id: String
        public let revision: Int
    }
    public let sessionId: String
    public let requestId: String
    public let action: String
    public let ref: Ref
}

public struct DSHGoalActivation: Codable, Sendable, Equatable {
    public let sessionId: String
    public let id: String
    public let revision: Int
    public let activation: String
}

public struct DSHGoalRound: Codable, Sendable, Equatable {
    public let sessionId: String
    public let id: String
    public let round: Int
}

public struct DSHQuestionIntent: Codable, Sendable, Equatable {
    public let kind: String
    public let approve: String
    public init(kind: String, approve: String) { self.kind = kind; self.approve = approve }
}

public struct DSHQuestion: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let question: String
    public let header: String?
    /// Supporting detail, such as a plan submitted for review.
    public let detail: String?
    public let options: [DSHQuestionOption]?
    public let multiSelect: Bool?
    public let intent: DSHQuestionIntent?

    public init(id: String, question: String, header: String? = nil, detail: String? = nil,
                options: [DSHQuestionOption]? = nil, multiSelect: Bool? = nil,
                intent: DSHQuestionIntent? = nil) {
        self.id = id; self.question = question; self.header = header; self.detail = detail
        self.options = options; self.multiSelect = multiSelect
        self.intent = intent
    }
}

public struct DSHQuestionRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionId: String
    public let questions: [DSHQuestion]
    public let expiresAt: Int64?

    public let stateVersion: DSHDecisionVersion?
    public init(id: String, sessionId: String, questions: [DSHQuestion], expiresAt: Int64? = nil,
                stateVersion: DSHDecisionVersion? = nil) {
        self.id = id; self.sessionId = sessionId
        self.questions = questions; self.expiresAt = expiresAt
        self.stateVersion = stateVersion
    }
}

public struct DSHQuestionResolution: Codable, Sendable, Equatable {
    public let id: String
    public let sessionId: String

    public let stateVersion: DSHDecisionVersion?
    public init(id: String, sessionId: String, stateVersion: DSHDecisionVersion? = nil) {
        self.id = id; self.sessionId = sessionId; self.stateVersion = stateVersion
    }
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
    public let httpStatus: Int?

    public init(code: String, message: String, retryable: Bool = false, httpStatus: Int? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.httpStatus = httpStatus
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

public struct DSHDiscardedMessage: Codable, Sendable, Equatable {
    public let messageId: String
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
    case assistantMessageDiscarded(DSHDiscardedMessage)
    case toolStarted(DSHToolActivity)
    case toolCompleted(DSHToolActivity)
    case approvalRequested(DSHApprovalRequest)
    case approvalResolved(DSHApprovalResolution)
    case turnStateChanged(DSHTurnState)
    case modelCatalog(DSHModelCatalog)
    case workspaceCatalog([DSHWorkspaceOption])
    case workspaceCreated(DSHWorkspaceOption)
    case modeCatalog(DSHModeCatalog)
    case directoryListing(DSHDirectoryListing)
    case workspaceFiles(DSHWorkspaceFiles)
    case workspaceBytes(DSHWorkspaceBytes)
    case usageUpdated(DSHUsageUpdate)
    case permissionUpdated(DSHPermissionUpdate)
    case sessionMetadataUpdated(DSHSessionMetadataUpdate)
    case modelChanged(DSHModelChangeNotice)
    case commandResult(DSHCommandResult)
    case attachmentUploaded(DSHUploadedAttachment)
    case promptAccepted(DSHPromptAccepted)
    case assistantReasoning(DSHReasoning)
    case questionAsked(DSHQuestionRequest)
    case questionResolved(DSHQuestionResolution)
    case planChanged(DSHPlanState)
    case todoChanged(DSHTodoState)
    case jobsChanged(DSHJobsState)
    case queueChanged(DSHServerQueue)
    case queueUpdated(DSHQueueUpdated)
    case subagentCatalog(DSHSubagentCatalog)
    case subagentCatalogInvalidated(DSHSubagentCatalogInvalidated)
    case subagentReceipt(DSHSubagentReceipt)
    case decisionsSnapshot(DSHDecisionsSnapshot)
    case sessionForked(DSHSessionForked)
    case commandCatalog(DSHCommandCatalog)
    case commandCatalogInvalidated(DSHCommandCatalogInvalidated)
    case goalChanged(DSHGoalState)
    case goalState(DSHGoalState)
    case goalUpdated(DSHGoalUpdated)
    case feedbackState(DSHFeedbackState)
    case feedbackChanged(DSHFeedbackChange)
    case feedbackUpdated(DSHFeedbackReceipt)
    case referenceCandidates(DSHReferenceCandidates)
    case searchResults(DSHSearchResults)
    case historyWindow(DSHHistoryWindow)
    case historyPage(DSHHistoryPage)
    case scheduleProjection(DSHScheduleProjection)
    case configurationInvalidated(DSHConfigurationInvalidation)
    case configurationModels(DSHDiscoveredModels)
    case configurationResult(DSHConfigurationResult)
    case configurationUpdated(DSHConfigurationReceipt)
    case planProjection(DSHPlanProjection)
    case workflowChanged(DSHWorkflowChanged)
    case executionRecorded(DSHExecutionRecorded)
    case executionPage(DSHExecutionPage)
    case goalActivation(DSHGoalActivation)
    case goalRound(DSHGoalRound)
    case protocolError(DSHProtocolError)
    case historyStarted(DSHHistoryBatch)
    case historyCompleted(DSHHistoryBatch)
    case unknown
}

public struct DSHEvent: Codable, Sendable, Equatable, Identifiable {
    public let envelope: DSHEnvelope
    public let kind: DSHEventKind
    /// Transport-only provenance: a lower sequence belongs to a session-list
    /// request made by this client after the Connector restarted. It is never
    /// encoded on the wire and lets the reducer distinguish it from a stale
    /// replayed snapshot.
    public let establishesSequenceEpoch: Bool

    public var id: String { envelope.messageId }
    public var sequence: Int64 { envelope.sequence }
    public var type: String { envelope.type }

    public init(envelope: DSHEnvelope, establishesSequenceEpoch: Bool = false) {
        self.envelope = envelope
        self.kind = DSHEvent.decodeKind(type: envelope.type, payload: envelope.payload)
        self.establishesSequenceEpoch = establishesSequenceEpoch
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
        case "assistant.message.discarded": return decode(DSHDiscardedMessage.self, payload).map(DSHEventKind.assistantMessageDiscarded) ?? .unknown
        case "assistant.message.completed": return decode(DSHChatMessage.self, payload).map(DSHEventKind.assistantMessageCompleted) ?? .unknown
        case "tool.started": return decode(DSHToolActivity.self, payload).map(DSHEventKind.toolStarted) ?? .unknown
        case "tool.completed": return decode(DSHToolActivity.self, payload).map(DSHEventKind.toolCompleted) ?? .unknown
        case "approval.requested": return decode(DSHApprovalRequest.self, payload).map(DSHEventKind.approvalRequested) ?? .unknown
        case "approval.resolved": return decode(DSHApprovalResolution.self, payload).map(DSHEventKind.approvalResolved) ?? .unknown
        case "turn.state.changed": return decode(DSHTurnState.self, payload).map(DSHEventKind.turnStateChanged) ?? .unknown
        case "model.catalog": return decode(DSHModelCatalog.self, payload).map(DSHEventKind.modelCatalog) ?? .unknown
        case "workspace.catalog":
            struct Payload: Decodable { let workspaces: [DSHWorkspaceOption] }
            return decode(Payload.self, payload).map { .workspaceCatalog($0.workspaces) } ?? .unknown
        case "workspace.created": return decode(DSHWorkspaceOption.self, payload).map(DSHEventKind.workspaceCreated) ?? .unknown
        case "mode.catalog": return decode(DSHModeCatalog.self, payload).map(DSHEventKind.modeCatalog) ?? .unknown
        case "directory.list": return decode(DSHDirectoryListing.self, payload).map(DSHEventKind.directoryListing) ?? .unknown
        case "usage.updated": return decode(DSHUsageUpdate.self, payload).map(DSHEventKind.usageUpdated) ?? .unknown
        case "permission.updated": return decode(DSHPermissionUpdate.self, payload).map(DSHEventKind.permissionUpdated) ?? .unknown
        case "session.metadata.updated": return decode(DSHSessionMetadataUpdate.self, payload).map(DSHEventKind.sessionMetadataUpdated) ?? .unknown
        case "session.model.changed": return decode(DSHModelChangeNotice.self, payload).map(DSHEventKind.modelChanged) ?? .unknown
        case "command.result": return decode(DSHCommandResult.self, payload).map(DSHEventKind.commandResult) ?? .unknown
        case "attachment.uploaded": return decode(DSHUploadedAttachment.self, payload).map(DSHEventKind.attachmentUploaded) ?? .unknown
        case "prompt.accepted": return decode(DSHPromptAccepted.self, payload).map(DSHEventKind.promptAccepted) ?? .unknown
        case "assistant.reasoning": return decode(DSHReasoning.self, payload).map(DSHEventKind.assistantReasoning) ?? .unknown
        case "question.asked": return decode(DSHQuestionRequest.self, payload).map(DSHEventKind.questionAsked) ?? .unknown
        case "plan.changed": return decode(DSHPlanState.self, payload).map(DSHEventKind.planChanged) ?? .unknown
        case "todo.changed": return decode(DSHTodoState.self, payload).map(DSHEventKind.todoChanged) ?? .unknown
        case "jobs.changed": return decode(DSHJobsState.self, payload).map(DSHEventKind.jobsChanged) ?? .unknown
        case "queue.changed": return decode(DSHServerQueue.self, payload).map(DSHEventKind.queueChanged) ?? .unknown
        case "queue.updated": return decode(DSHQueueUpdated.self, payload).map(DSHEventKind.queueUpdated) ?? .unknown
        case "subagent.catalog": return decode(DSHSubagentCatalog.self, payload).map(DSHEventKind.subagentCatalog) ?? .unknown
        case "workspace.files": return decode(DSHWorkspaceFiles.self, payload).map(DSHEventKind.workspaceFiles) ?? .unknown
        case "workspace.bytes": return decode(DSHWorkspaceBytes.self, payload).map(DSHEventKind.workspaceBytes) ?? .unknown
        case "subagent.catalog.invalidated": return decode(DSHSubagentCatalogInvalidated.self, payload).map(DSHEventKind.subagentCatalogInvalidated) ?? .unknown
        case "subagent.receipt": return decode(DSHSubagentReceipt.self, payload).map(DSHEventKind.subagentReceipt) ?? .unknown
        case "decisions.snapshot": return decode(DSHDecisionsSnapshot.self, payload).map(DSHEventKind.decisionsSnapshot) ?? .unknown
        case "session.forked": return decode(DSHSessionForked.self, payload).map(DSHEventKind.sessionForked) ?? .unknown
        case "command.catalog": return decode(DSHCommandCatalog.self, payload).map(DSHEventKind.commandCatalog) ?? .unknown
        case "command.catalog.invalidated": return decode(DSHCommandCatalogInvalidated.self, payload).map(DSHEventKind.commandCatalogInvalidated) ?? .unknown
        case "goal.changed": return decode(DSHGoalState.self, payload).map(DSHEventKind.goalChanged) ?? .unknown
        case "goal.state": return decode(DSHGoalState.self, payload).map(DSHEventKind.goalState) ?? .unknown
        case "goal.updated": return decode(DSHGoalUpdated.self, payload).map(DSHEventKind.goalUpdated) ?? .unknown
        case "feedback.state": return decode(DSHFeedbackState.self, payload).map(DSHEventKind.feedbackState) ?? .unknown
        case "feedback.changed": return decode(DSHFeedbackChange.self, payload).map(DSHEventKind.feedbackChanged) ?? .unknown
        case "feedback.updated": return decode(DSHFeedbackReceipt.self, payload).map(DSHEventKind.feedbackUpdated) ?? .unknown
        case "reference.candidates": return decode(DSHReferenceCandidates.self, payload).map(DSHEventKind.referenceCandidates) ?? .unknown
        case "search.results": return decode(DSHSearchResults.self, payload).map(DSHEventKind.searchResults) ?? .unknown
        case "history.window": return decode(DSHHistoryWindow.self, payload).map(DSHEventKind.historyWindow) ?? .unknown
        case "history.page": return decode(DSHHistoryPage.self, payload).map(DSHEventKind.historyPage) ?? .unknown
        case "schedule.projection": return decode(DSHScheduleProjection.self, payload).map(DSHEventKind.scheduleProjection) ?? .unknown
        case "configuration.invalidated": return decode(DSHConfigurationInvalidation.self, payload).map(DSHEventKind.configurationInvalidated) ?? .unknown
        case "configuration.models": return decode(DSHDiscoveredModels.self, payload).map(DSHEventKind.configurationModels) ?? .unknown
        case "configuration.result": return decode(DSHConfigurationResult.self, payload).map(DSHEventKind.configurationResult) ?? .unknown
        case "configuration.updated": return decode(DSHConfigurationReceipt.self, payload).map(DSHEventKind.configurationUpdated) ?? .unknown
        case "plan.projection": return decode(DSHPlanProjection.self, payload).map(DSHEventKind.planProjection) ?? .unknown
        case "workflow.changed": return decode(DSHWorkflowChanged.self, payload).map(DSHEventKind.workflowChanged) ?? .unknown
        case "execution.recorded": return decode(DSHExecutionRecorded.self, payload).map(DSHEventKind.executionRecorded) ?? .unknown
        case "execution.page": return decode(DSHExecutionPage.self, payload).map(DSHEventKind.executionPage) ?? .unknown
        case "goal.activation": return decode(DSHGoalActivation.self, payload).map(DSHEventKind.goalActivation) ?? .unknown
        case "goal.round": return decode(DSHGoalRound.self, payload).map(DSHEventKind.goalRound) ?? .unknown
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

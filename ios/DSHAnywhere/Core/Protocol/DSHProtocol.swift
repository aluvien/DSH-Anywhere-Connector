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
        if !attachments.isEmpty { payload["content"] = .array(attachments) }
        return DSHCommand(requestId: requestId, deviceId: deviceId, machineId: machineId,
                          sessionId: sessionId, type: "prompt.send", payload: .object(payload))
    }

    public static func listSessions(deviceId: String, machineId: String,
                                    includeArchived: Bool = false) -> DSHCommand {
        DSHCommand(deviceId: deviceId, machineId: machineId, type: "session.list",
                   payload: .object(["includeArchived": .bool(includeArchived)]))
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
public struct DSHPairingLink: Equatable, Sendable {
    public let relay: String
    public let machineId: String
    public let pairingSecret: String

    /// Returns nil for anything that is not a complete pairing code, so the
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
              let pairingSecret = value("secret"), !pairingSecret.isEmpty,
              let relayURL = URL(string: relay),
              let scheme = relayURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }

        self.relay = relay
        self.machineId = machineId
        self.pairingSecret = pairingSecret
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
                usage: DSHSessionUsage? = nil) {
        self.id = id; self.title = title; self.updatedAt = updatedAt
        self.cwd = cwd; self.workspaceId = workspaceId; self.workspaceName = workspaceName
        self.archived = archived; self.running = running; self.blank = blank
        self.parentSessionId = parentSessionId; self.provider = provider; self.model = model
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

public struct DSHChatMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let role: DSHMessageRole
    public var markdown: String
    public var usage: DSHSessionUsage?
    public var provider: String?
    public var model: String?
    public var reasoningEffort: String?
    public var contextWindow: Double?
    /// Chain-of-thought for this message, kept out of `markdown` so the reply
    /// reads cleanly; the transcript folds it behind a disclosure.
    public var reasoning: String?

    public init(id: String, role: DSHMessageRole, markdown: String,
                usage: DSHSessionUsage? = nil, provider: String? = nil, model: String? = nil,
                reasoningEffort: String? = nil, contextWindow: Double? = nil,
                reasoning: String? = nil) {
        self.id = id; self.role = role; self.markdown = markdown; self.usage = usage
        self.provider = provider; self.model = model; self.reasoningEffort = reasoningEffort
        self.contextWindow = contextWindow; self.reasoning = reasoning
    }
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

public struct DSHCommandResult: Codable, Sendable, Equatable, Identifiable {
    public let sessionId: String
    public let requestId: String
    public let matched: Bool
    public let commandId: String?
    public let kind: String?
    public let text: String?
    public var id: String { requestId }
    public init(sessionId: String, requestId: String, matched: Bool,
                commandId: String? = nil, kind: String? = nil, text: String? = nil) {
        self.sessionId = sessionId; self.requestId = requestId; self.matched = matched
        self.commandId = commandId; self.kind = kind; self.text = text
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

    public init(id: String, name: String, status: String = "running", detail: String? = nil) {
        self.id = id; self.name = name; self.status = status; self.detail = detail
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

public struct DSHTurnState: Codable, Sendable, Equatable {
    public let sessionId: String
    public let state: String

    public init(sessionId: String, state: String) { self.sessionId = sessionId; self.state = state }
}

public enum DSHEventKind: Sendable, Equatable {
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
    case commandResult(DSHCommandResult)
    case attachmentUploaded(DSHUploadedAttachment)
    case assistantReasoning(DSHReasoning)
    case questionAsked(DSHQuestionRequest)
    case questionResolved(DSHQuestionResolution)
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
        case "command.result": return decode(DSHCommandResult.self, payload).map(DSHEventKind.commandResult) ?? .unknown
        case "attachment.uploaded": return decode(DSHUploadedAttachment.self, payload).map(DSHEventKind.attachmentUploaded) ?? .unknown
        case "assistant.reasoning": return decode(DSHReasoning.self, payload).map(DSHEventKind.assistantReasoning) ?? .unknown
        case "question.asked": return decode(DSHQuestionRequest.self, payload).map(DSHEventKind.questionAsked) ?? .unknown
        case "question.resolved": return decode(DSHQuestionResolution.self, payload).map(DSHEventKind.questionResolved) ?? .unknown
        default: return .unknown
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(envelope: try DSHEnvelope(from: decoder))
    }

    public func encode(to encoder: Encoder) throws { try envelope.encode(to: encoder) }
}

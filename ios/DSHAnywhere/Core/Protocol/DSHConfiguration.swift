import Foundation

public struct DSHSettingsNamespace: Codable, Sendable, Equatable, Identifiable {
    public struct Secret: Codable, Sendable, Equatable { public let path: [String]; public let set: Bool }
    public let ns: String
    public let schema: DSHJSONValue
    public let value: DSHJSONValue
    public let base: DSHJSONValue?
    public let user: DSHJSONValue?
    public let applies: String
    public let secrets: [Secret]
    public let revision: Int64
    public var id: String { ns }
}
public struct DSHSettingsSnapshot: Codable, Sendable, Equatable {
    public let writable: Bool
    public let hasDocument: Bool
    public let namespaces: [DSHSettingsNamespace]
}
public struct DSHPluginInventory: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public let entryId: String
        public let moduleName: String
        public let enabled: Bool
        public let fiberPhase: String?
        public var id: String { entryId }
    }
    public struct Preset: Codable, Sendable, Equatable, Identifiable {
        public struct Row: Codable, Sendable, Equatable {
            public let entryId: String?
            public let moduleName: String
            public let enabled: DSHJSONValue
            public let condition: String?
            public let fiberPhase: String?
        }
        public let id: String
        public let trust: String
        public let name: String?
        public let isDefault: Bool
        public let broken: String?
        public let rows: [Row]
    }
    public let entries: [Entry]
    public let agentPresets: [Preset]?
}
public struct DSHProviderDirectory: Codable, Sendable, Equatable {
    public struct Registered: Codable, Sendable, Equatable { public let id: String; public let name: String }
    public struct Configurable: Codable, Sendable, Equatable, Identifiable {
        public let provider: String
        public let displayName: String
        public let settingsNs: String
        public let settingsPath: [String]
        public let declared: Bool?
        public let error: String?
        public var id: String { provider }
    }
    public let registered: [Registered]
    public let configurable: [Configurable]
}
public struct DSHCredentialInfo: Codable, Sendable, Equatable { public let configured: Bool; public let source: String?; public let writable: Bool }
public struct DSHConfigurationResult: Codable, Sendable, Equatable {
    public let section: String
    public let value: DSHJSONValue
    public func decoded<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(value)) }
}
public struct DSHConfigurationReceipt: Codable, Sendable, Equatable {
    public let kind: String
    public let requestId: String
    public let namespace: DSHSettingsNamespace?
    public let ref: String?
}
public struct DSHConfigurationInvalidation: Codable, Sendable, Equatable {
    public let section: String
    public let ns: String?
    public let ref: String?
    func affects(namespace: String) -> Bool { section == "settings" && ns == namespace }
    func affects(credential: String) -> Bool { section == "credentials" && (ref == nil || ref == credential) }
}
public struct DSHDiscoveredModels: Codable, Sendable, Equatable {
    public struct Model: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String?
        public let contextWindow: Double?
        public let maxTokens: Double?
        var value: DSHJSONValue {
            var row: [String: DSHJSONValue] = ["id": .string(id)]
            if let name { row["name"] = .string(name) }
            if let contextWindow { row["contextWindow"] = .number(contextWindow) }
            if let maxTokens { row["maxTokens"] = .number(maxTokens) }
            return .object(row)
        }
    }
    public let settingsNs: String
    public let models: [Model]
    func appending(to current: [DSHJSONValue], selected: Set<String>) -> [DSHJSONValue] {
        var known = Set(current.compactMap { $0.executionObject["id"]?.executionString })
        return current + models.filter { selected.contains($0.id) && known.insert($0.id).inserted }.map(\.value)
    }
}
struct DSHConfigurationRequestError: LocalizedError {
    let failure: DSHProtocolError
    var errorDescription: String? { failure.message }
    var definitelyNotCommitted: Bool { failure.code == "bridge-request-failed" && failure.httpStatus.map { (400..<500).contains($0) } == true }
}

struct DSHConfigurationEdit: Codable, Equatable, Identifiable {
    var op: String
    var path: [String]
    var value: DSHJSONValue?
    var id: String { DSHJSONValue.array(path.map(DSHJSONValue.string)).executionPrettyJSON }
    var payload: DSHJSONValue {
        var row: [String: DSHJSONValue] = ["op": .string(op), "path": .array(path.map(DSHJSONValue.string))]
        if op == "set" { row["value"] = value ?? .null }
        return .object(row)
    }
}
struct DSHConfigurationDraft: Codable, Equatable {
    var base: DSHSettingsNamespace
    var value: DSHJSONValue
    var edits: [DSHConfigurationEdit] = []
    var pending: DSHCommand?
    var rawNumbers: [String: String] = [:]
    var invalidNumbers: Set<String> = []
    var rawJSON: [String: String] = [:]
    var unappliedJSON: Set<String> = []
    init(base: DSHSettingsNamespace) { self.base = base; value = base.value }
    mutating func edit(path: [String], value newValue: DSHJSONValue?, arrayRoot: [String]? = nil) {
        let old = value.configurationValue(at: path)
        func container(_ value: DSHJSONValue?) -> Bool { switch value { case .array, .object: true; default: false } }
        var clearRoot: [String]?
        if container(old) || container(newValue) { clearRoot = path }
        if let arrayRoot, newValue == nil, path.count == arrayRoot.count + 1 { clearRoot = arrayRoot }
        if let clearRoot {
            func isInside(_ key: String) -> Bool { (try? JSONDecoder().decode([String].self, from: Data(key.utf8)))?.starts(with: clearRoot) == true }
            rawNumbers = rawNumbers.filter { !isInside($0.key) }
            rawJSON = rawJSON.filter { !isInside($0.key) }
            invalidNumbers = invalidNumbers.filter { !isInside($0) }
            unappliedJSON = unappliedJSON.filter { !isInside($0) }
        }
        value = value.configurationReplacing(path, with: newValue) ?? .object([:])
        let ancestor = edits.first { $0.op == "set" && path.starts(with: $0.path) }?.path
        let target = ancestor ?? arrayRoot ?? path
        edits.removeAll { $0.path.starts(with: target) }
        let current = value.configurationValue(at: target)
        edits.append(.init(op: current == nil ? "unset" : "set", path: target, value: current))
    }
    mutating func merge(onto latest: DSHSettingsNamespace) {
        var merged = latest.value
        for edit in edits { merged = merged.configurationReplacing(edit.path, with: edit.op == "set" ? edit.value : nil) ?? .object([:]) }
        base = latest; value = merged; pending = nil
    }
    var payload: DSHJSONValue { .object(["kind": .string("settings"), "ns": .string(base.ns), "expectedRevision": .number(Double(base.revision)), "ops": .array(edits.map(\.payload))]) }
}

struct DSHConfigurationSchema {
    let document: DSHJSONValue
    func node(_ reference: DSHJSONValue?) -> [String: DSHJSONValue] {
        guard let reference else { return [:] }
        let refs = document.executionObject["refs"]?.executionObject ?? [:]
        let key: String?
        switch reference {
        case .number(let number): key = number.isFinite && number >= 0 && number < 9_007_199_254_740_991 && number.rounded() == number ? String(Int64(number)) : nil
        case .string(let string): key = string
        default: key = nil
        }
        if let key { return refs[key]?.executionObject ?? [:] }
        let object = reference.executionObject
        if object["type"] == nil, let uid = object["uid"] { return node(uid) }
        return object
    }
    var root: [String: DSHJSONValue] { node(document) }
    func at(_ path: [String]) -> [String: DSHJSONValue] {
        var current = root
        for key in path {
            let kind = current["type"]?.executionString
            if kind == "object" { current = node(current["dict"]?.executionObject[key]) }
            else if kind == "dict" || kind == "array" { current = node(current["inner"]) }
            else { return [:] }
        }
        return current
    }
    func choices(_ node: [String: DSHJSONValue]) -> [DSHJSONValue]? {
        guard node["type"] == .string("union"), let list = node["list"]?.executionArray, !list.isEmpty else { return nil }
        let options = list.compactMap { entry -> DSHJSONValue? in let value = self.node(entry); return value["type"] == .string("const") ? value["value"] : nil }
        return options.count == list.count ? options : nil
    }
    func arrayRoot(in path: [String]) -> [String]? {
        for index in path.indices where at(Array(path.prefix(index)))["type"] == .string("array") { return Array(path.prefix(index)) }
        return nil
    }
}

extension DSHJSONValue {
    func configurationValue(at path: [String]) -> DSHJSONValue? {
        guard let key = path.first else { return self }
        let child: DSHJSONValue?
        switch self {
        case .object(let value): child = value[key]
        case .array(let value): child = Int(key).flatMap { value.indices.contains($0) ? value[$0] : nil }
        default: child = nil
        }
        return child?.configurationValue(at: Array(path.dropFirst()))
    }
    func configurationReplacing(_ path: [String], with replacement: DSHJSONValue?) -> DSHJSONValue? {
        guard let key = path.first else { return replacement }
        let rest = Array(path.dropFirst())
        if case .array(var values) = self {
            guard let index = Int(key), values.indices.contains(index) else { return self }
            if let updated = values[index].configurationReplacing(rest, with: replacement) { values[index] = updated }
            else { values.remove(at: index) }
            return .array(values)
        }
        var object = executionObject
        let child = object[key] ?? .object([:])
        object[key] = child.configurationReplacing(rest, with: replacement)
        return .object(object)
    }
}

/// Settings edits can contain newly typed secrets. Keep the whole draft and
/// its unconfirmed request identity in Keychain, never in JSON disk journals.
struct DSHSecureConfigurationStorage {
    let tokens: any DSHTokenStore
    init(tokens: any DSHTokenStore = DSHKeychainTokenStore(service: "com.dshanywhere.configuration")) { self.tokens = tokens }
    func key(machine: String, device: String, scope: String) -> String { Data((try? JSONEncoder().encode([machine, device, scope])) ?? Data()).base64EncodedString() }
    @discardableResult func save<T: Encodable>(_ value: T, key: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let text = String(data: try encoder.encode(value), encoding: .utf8) else { throw DSHKeychainError.invalidData }
        try tokens.save(text, account: key)
        return text
    }
    /// UI editors run on MainActor. Compare one Keychain read before writing
    /// so a late receipt from another open editor cannot erase newer input.
    @MainActor @discardableResult func save<T: Encodable>(_ value: T, key: String, expecting expected: String?) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let text = String(data: try encoder.encode(value), encoding: .utf8) else { throw DSHKeychainError.invalidData }
        let current = try tokens.read(account: key)
        guard current == expected || current == text else { throw DSHConfigurationDraftChanged() }
        if current != text { try tokens.save(text, account: key) }
        return text
    }
    func loadRecord<T: Decodable>(_ type: T.Type, key: String) throws -> (value: T?, token: String?) {
        let text = try tokens.read(account: key)
        return (try text.map { try JSONDecoder().decode(type, from: Data($0.utf8)) }, text)
    }
    func load<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        guard let text = try tokens.read(account: key) else { return nil }
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }
    func delete(key: String) throws { try tokens.delete(account: key) }
}
struct DSHConfigurationDraftChanged: LocalizedError {
    var errorDescription: String? { "另一页面已更新安全草稿，本页不会覆盖它；请返回并重新打开。" }
}

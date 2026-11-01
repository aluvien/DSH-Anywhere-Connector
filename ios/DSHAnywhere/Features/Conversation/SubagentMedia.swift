import Foundation
import CryptoKit
import Combine

struct DSHSubagentDraftError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct DSHSubagentDraftAddress: Hashable, Sendable {
    let machineID: String
    let parentID: String
    let childID: String
    var key: String { (try? JSONEncoder().encode([machineID, parentID, childID]))?.base64EncodedString() ?? "" }
    var legacyTextKey: String { "dsh.subagent.draft." + Data([machineID, parentID, childID].joined(separator: "\u{0}").utf8).base64EncodedString() }
}

actor DSHSubagentMediaStorage {
    private let directory: URL
    private var revisions: [String: Int] = [:]
    init(directory: URL? = nil) {
        self.directory = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("DSHAnywhere/SubagentImageDrafts", isDirectory: true)
    }
    private func url(_ key: String) -> URL {
        directory.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }
    func load(_ key: String) throws -> [DSHStagedAttachment] {
        let path = url(key)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let value = try JSONDecoder().decode([DSHStagedAttachment].self, from: Data(contentsOf: path))
        try Self.validate(value)
        return value
    }
    /// Out-of-order tasks cannot overwrite a later composition revision.
    func save(_ images: [DSHStagedAttachment], key: String, revision: Int) throws {
        guard revision >= revisions[key, default: -1] else { return }
        try Self.validate(images)
        if images.isEmpty {
            if FileManager.default.fileExists(atPath: url(key).path) { try FileManager.default.removeItem(at: url(key)) }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(images).write(to: url(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        revisions[key] = revision
    }
    static func validate(_ images: [DSHStagedAttachment]) throws {
        guard images.count <= 4, images.allSatisfy({ $0.isImage && !$0.data.isEmpty }),
              images.reduce(0, { $0 + $1.data.count }) <= 6 * 1_024 * 1_024 else {
            throw DSHSubagentDraftError(message: "子任务最多附带 4 张图片，图片合计不能超过 6 MiB。")
        }
    }
}

/// One shared composition per exact parent/child address. An acknowledgement
/// from a closing reader also updates a newly opened reader, preventing a
/// previously accepted picture from remaining available to send a second time.
@MainActor
final class DSHSubagentComposerDrafts: ObservableObject {
    static let shared = DSHSubagentComposerDrafts()
    @Published private var texts: [String: String] = [:]
    @Published private var deliveries: [String: String] = [:]
    @Published private var media: [String: [DSHStagedAttachment]] = [:]
    @Published private var loaded: Set<String> = []
    private var revisions: [String: Int] = [:]
    private let storage: DSHSubagentMediaStorage
    private let defaults: UserDefaults

    init(storage: DSHSubagentMediaStorage = DSHSubagentMediaStorage(), defaults: UserDefaults = .standard) {
        self.storage = storage; self.defaults = defaults
    }
    private func textKey(_ address: DSHSubagentDraftAddress) -> String { "dsh.subagent.composer." + address.key }
    func text(for address: DSHSubagentDraftAddress) -> String {
        texts[address.key] ?? defaults.string(forKey: textKey(address)) ?? defaults.string(forKey: address.legacyTextKey) ?? ""
    }
    func delivery(for address: DSHSubagentDraftAddress) -> String {
        deliveries[address.key] ?? (defaults.string(forKey: textKey(address) + ".delivery") == "steer" ? "steer" : "queue")
    }
    func images(for address: DSHSubagentDraftAddress) -> [DSHStagedAttachment] { media[address.key] ?? [] }
    func isLoaded(_ address: DSHSubagentDraftAddress) -> Bool { loaded.contains(address.key) }
    func setText(_ text: String, for address: DSHSubagentDraftAddress) {
        texts[address.key] = text
        if text.isEmpty { defaults.removeObject(forKey: textKey(address)) } else { defaults.set(text, forKey: textKey(address)) }
        defaults.removeObject(forKey: address.legacyTextKey)
    }
    func setDelivery(_ delivery: String, for address: DSHSubagentDraftAddress) {
        deliveries[address.key] = delivery
        defaults.set(delivery, forKey: textKey(address) + ".delivery")
    }
    func load(_ address: DSHSubagentDraftAddress) async throws {
        guard !loaded.contains(address.key) else { return }
        let revision = revisions[address.key, default: 0]
        let consumed = Set(defaults.stringArray(forKey: textKey(address) + ".consumed-images") ?? [])
        let images = try await storage.load(address.key).filter { !consumed.contains($0.id.uuidString) }
        if revision == revisions[address.key, default: 0] { media[address.key] = images }
        loaded.insert(address.key)
    }
    func setImages(_ images: [DSHStagedAttachment], for address: DSHSubagentDraftAddress) async throws {
        try DSHSubagentMediaStorage.validate(images)
        media[address.key] = images; loaded.insert(address.key)
        revisions[address.key, default: 0] += 1
        try await storage.save(images, key: address.key, revision: revisions[address.key]!)
    }
    func persist(_ address: DSHSubagentDraftAddress) async throws {
        guard isLoaded(address) else { throw DSHSubagentDraftError(message: "图片草稿尚未读取，请重新载入后再发送。") }
        try await storage.save(images(for: address), key: address.key, revision: revisions[address.key, default: 0])
    }
    func removeImage(_ id: UUID, for address: DSHSubagentDraftAddress) async throws {
        try await setImages(images(for: address).filter { $0.id != id }, for: address)
    }
    func consume(text: String, delivery: String, images: [DSHStagedAttachment], address: DSHSubagentDraftAddress) async throws {
        guard self.text(for: address) == text, self.delivery(for: address) == delivery, self.images(for: address) == images else { return }
        // A tiny confirmed receipt also fences a file that could not be
        // deleted (e.g. storage is full); reopening cannot offer it to resend.
        if !images.isEmpty { defaults.set(images.map { $0.id.uuidString }, forKey: textKey(address) + ".consumed-images") }
        setText("", for: address)
        try await setImages([], for: address)
    }
}

extension DSHStagedAttachment {
    var subagentImagePart: DSHJSONValue {
        .object(["type": .string("image"), "mediaType": .string("image/jpeg"), "data": .string(data.base64EncodedString()), "name": .string(name)])
    }
}

import Foundation
import Security

public enum DSHKeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData
}

public protocol DSHTokenStore: Sendable {
    func save(_ token: String, account: String) throws
    func read(account: String) throws -> String?
    func delete(account: String) throws
}

/// Stores the per-device bearer token in the iOS Keychain.  The service is
/// configurable so tests and app extensions can use an isolated namespace.
public final class DSHKeychainTokenStore: DSHTokenStore, @unchecked Sendable {
    private let service: String
    private let accessGroup: String?

    public init(service: String = "com.dshanywhere.auth", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func save(_ token: String, account: String) throws {
        var query = baseQuery(account: account)
        let data = Data(token.utf8)
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw DSHKeychainError.unexpectedStatus(updateStatus)
        }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw DSHKeychainError.unexpectedStatus(addStatus) }
    }

    public func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DSHKeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw DSHKeychainError.invalidData
        }
        return token
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DSHKeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

/// A lightweight in-memory implementation useful for previews and unit tests.
public final class DSHInMemoryTokenStore: DSHTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}
    public func save(_ token: String, account: String) { lock.lock(); defer { lock.unlock() }; values[account] = token }
    public func read(account: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    public func delete(account: String) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
}

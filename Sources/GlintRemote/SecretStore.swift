import Foundation
import GlintCore
import Security

/// Where S3 secret keys are kept. Never the index database.
public protocol SecretStore: Sendable {
    func read(_ id: String) throws -> String?
    func save(_ secret: String, id: String) throws
    func delete(_ id: String)
}

/// The login Keychain, one generic password per credential.
public struct KeychainSecretStore: SecretStore {
    public var service: String

    public init(service: String = "app.glint.remote-sources") {
        self.service = service
    }

    public func read(_ id: String) throws -> String? {
        var query = base(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Self.error(status) }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ secret: String, id: String) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(base(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Self.error(update) }
        var item = base(id)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "Glint remote source"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(status) }
    }

    public func delete(_ id: String) {
        SecItemDelete(base(id) as CFDictionary)
    }

    private func base(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }

    private static func error(_ status: OSStatus) -> RemoteStorageError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .misconfigured("Keychain: \(message)")
    }
}

/// Secrets in memory, for tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    public init(_ secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    public func read(_ id: String) throws -> String? { lock.withLock { secrets[id] } }
    public func save(_ secret: String, id: String) throws { lock.withLock { secrets[id] = secret } }
    public func delete(_ id: String) { lock.withLock { secrets[id] = nil } }
    public var ids: Set<String> { lock.withLock { Set(secrets.keys) } }
}

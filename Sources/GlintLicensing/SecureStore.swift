import Foundation
import Security

/// Small secret storage for license tokens, the trial clock and the install id.
public protocol SecureStore: Sendable {
    func data(for key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
    func remove(_ key: String) throws
}

extension SecureStore {
    public func string(for key: String) throws -> String? {
        try data(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setString(_ value: String, for key: String) throws {
        try set(Data(value.utf8), for: key)
    }

    public func date(for key: String) throws -> Date? {
        try string(for: key).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    }

    public func setDate(_ date: Date, for key: String) throws {
        try setString(String(date.timeIntervalSince1970), for: key)
    }
}

/// Keychain-backed store (generic passwords under one service).
public struct KeychainStore: SecureStore {
    public let service: String

    public init(service: String = "app.glint.mac") {
        self.service = service
    }

    public func data(for key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw LicenseError.storage(status: status)
        }
    }

    public func set(_ data: Data, for key: String) throws {
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery(key)
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw LicenseError.storage(status: addStatus) }
        } else if status != errSecSuccess {
            throw LicenseError.storage(status: status)
        }
    }

    public func remove(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LicenseError.storage(status: status)
        }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// In-memory store for tests and previews.
public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data]

    public init(_ values: [String: Data] = [:]) {
        self.values = values
    }

    public func data(for key: String) throws -> Data? {
        lock.withLock { values[key] }
    }

    public func set(_ data: Data, for key: String) throws {
        lock.withLock { values[key] = data }
    }

    public func remove(_ key: String) throws {
        _ = lock.withLock { values.removeValue(forKey: key) }
    }
}

/// A random per-install identifier kept in the secure store. Not a hardware serial.
public enum InstallID {
    static let key = "install.id"

    /// Returns the install id, creating it on first use.
    public static func current(in store: any SecureStore) throws -> String {
        if let existing = try store.string(for: key) { return existing }
        let created = UUID().uuidString
        try store.setString(created, for: key)
        return created
    }
}

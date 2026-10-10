import Foundation

/// Minimal preferences storage, so tests can avoid `UserDefaults.standard`.
public protocol KeyValueStore: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

extension KeyValueStore {
    public func date(forKey key: String) -> Date? {
        string(forKey: key).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    }

    public func setDate(_ date: Date?, forKey key: String) {
        set(date.map { String($0.timeIntervalSince1970) }, forKey: key)
    }
}

/// `UserDefaults`-backed store. `UserDefaults` is documented as thread-safe.
public final class UserDefaultsKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }

    public func set(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// In-memory store for tests.
public final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func string(forKey key: String) -> String? { lock.withLock { values[key] } }

    public func set(_ value: String?, forKey key: String) {
        lock.withLock { values[key] = value }
    }
}

/// An anonymous id that rotates every 90 days, so events can be grouped per install over a
/// short window without a persistent identifier.
public enum AnonymousID {
    public static let rotationInterval: TimeInterval = 90 * 24 * 60 * 60
    static let idKey = "telemetry.anonymousID"
    static let createdKey = "telemetry.anonymousIDCreated"

    public static func current(in store: any KeyValueStore, now: Date) -> String {
        if let id = store.string(forKey: idKey), let created = store.date(forKey: createdKey),
            now.timeIntervalSince(created) < rotationInterval, now >= created
        {
            return id
        }
        let id = UUID().uuidString
        store.set(id, forKey: idKey)
        store.setDate(now, forKey: createdKey)
        return id
    }
}

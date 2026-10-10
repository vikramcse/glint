import Foundation

/// The 14-day Pro trial, tracked locally.
///
/// Light anti-tamper only: the start date lives in the Keychain, and setting the clock back
/// never adds time because elapsed time is measured from the latest date ever seen.
public struct TrialClock: Sendable {
    public enum Status: Sendable, Hashable {
        case notStarted
        case active(daysLeft: Int, endsAt: Date)
        case expired
    }

    public static let length: TimeInterval = 14 * 24 * 60 * 60

    static let startKey = "trial.start"
    static let lastSeenKey = "trial.lastSeen"

    private let store: any SecureStore
    private let now: @Sendable () -> Date

    public init(store: any SecureStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Starts the trial if it never started. Returns `true` when this call started it.
    @discardableResult
    public func startIfNeeded() throws -> Bool {
        guard try store.date(for: Self.startKey) == nil else { return false }
        let date = now()
        try store.setDate(date, for: Self.startKey)
        try store.setDate(date, for: Self.lastSeenKey)
        return true
    }

    /// Current trial status. Records the observed time so a later rollback is ignored.
    public func status() throws -> Status {
        guard let start = try store.date(for: Self.startKey) else { return .notStarted }
        let lastSeen = try store.date(for: Self.lastSeenKey) ?? start
        let effectiveNow = max(now(), lastSeen, start)
        if effectiveNow > lastSeen {
            try store.setDate(effectiveNow, for: Self.lastSeenKey)
        }
        let endsAt = start.addingTimeInterval(Self.length)
        let remaining = endsAt.timeIntervalSince(effectiveNow)
        guard remaining > 0 else { return .expired }
        let daysLeft = Int((remaining / 86_400).rounded(.up))
        return .active(daysLeft: daysLeft, endsAt: endsAt)
    }
}

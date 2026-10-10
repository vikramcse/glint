import Foundation
import GlintCore
import Observation

/// Owns the license lifecycle: trial, activation, deactivation and re-validation.
///
/// Pro works offline indefinitely after activation. The server is contacted only to activate,
/// deactivate and (at most weekly) check for revocation; network failures never lock anyone out.
///
/// **Development fallback:** when no `ActivationService` is configured (the M3 license server
/// does not exist yet), a correctly signed license key is accepted as its own activation. Seat
/// limits cannot be enforced in that mode.
@MainActor
@Observable
public final class LicenseManager {
    enum Keys {
        static let key = "license.key"
        static let activation = "license.activation"
        static let revoked = "license.revoked"
        static let seatLimit = "license.seatLimit"
        static let lastValidated = "license.lastValidated"
    }

    /// Minimum time between successful revocation checks.
    public static let revalidationInterval: TimeInterval = 7 * 24 * 60 * 60

    public private(set) var state: LicenseState = .none
    /// The last activation or deactivation failure, for the license sheet to show.
    public private(set) var lastError: LicenseError?
    /// Called on the main actor whenever `state` changes, so the app can push the new
    /// `FeatureGateSnapshot` into the shared `FeatureGateBox`.
    @ObservationIgnored public var onChange: ((Entitlements) -> Void)?

    public var entitlements: Entitlements { Entitlements(state: state) }

    @ObservationIgnored private let verifier: LicenseVerifier
    @ObservationIgnored private let store: any SecureStore
    @ObservationIgnored private let activationService: (any ActivationService)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let trial: TrialClock

    public init(
        verifier: LicenseVerifier,
        store: any SecureStore,
        activationService: (any ActivationService)?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.verifier = verifier
        self.store = store
        self.activationService = activationService
        self.now = now
        trial = TrialClock(store: store, now: now)
        state = computeState()
    }

    /// The random per-install id sent to the license server.
    public var installID: String {
        (try? InstallID.current(in: store)) ?? "unavailable"
    }

    /// Recomputes `state` from stored tokens and the trial clock (call at launch and daily).
    public func refresh() {
        apply(computeState())
    }

    /// Starts the 14-day trial on first launch. Returns `true` when this call started it.
    @discardableResult
    public func startTrialIfNeeded() -> Bool {
        let started: Bool
        do {
            started = try trial.startIfNeeded()
        } catch {
            Log.licensing.error("Could not start trial: \(String(describing: error), privacy: .public)")
            started = false
        }
        refresh()
        return started
    }

    /// Verifies `key` locally, activates it with the server when one is configured, and unlocks Pro.
    public func activate(key rawKey: String) async throws {
        let key = rawKey.filter { !$0.isWhitespace }
        do {
            _ = try verifier.verify(key, kind: .license)
            let token: String
            if let activationService {
                let installID = try InstallID.current(in: store)
                token = try await activationService.activate(key: key, installID: installID)
                _ = try verifier.verify(token, kind: .activation, installID: installID)
            } else {
                token = key
            }
            try store.setString(key, for: Keys.key)
            try store.setString(token, for: Keys.activation)
            try store.setDate(now(), for: Keys.lastValidated)
            try store.remove(Keys.revoked)
            try store.remove(Keys.seatLimit)
            lastError = nil
            refresh()
            Log.licensing.info("License activated")
        } catch {
            let licenseError = (error as? LicenseError) ?? .network
            lastError = licenseError
            switch licenseError {
            case .seatLimitReached: try? store.setString("1", for: Keys.seatLimit)
            case .revoked: try? store.setString("1", for: Keys.revoked)
            default: break
            }
            refresh()
            throw licenseError
        }
    }

    /// Frees this Mac's seat and returns to Free (or the trial, if still running).
    public func deactivate() async throws {
        if let activationService, let token = try? store.string(for: Keys.activation),
           let payload = try? verifier.verify(token), payload.kind == .activation {
            do {
                try await activationService.deactivate(activationToken: token, installID: installID)
            } catch {
                let licenseError = (error as? LicenseError) ?? .network
                lastError = licenseError
                throw licenseError
            }
        }
        for key in [Keys.key, Keys.activation, Keys.lastValidated, Keys.seatLimit] {
            try? store.remove(key)
        }
        lastError = nil
        refresh()
    }

    /// Checks the revocation list at most weekly. Network failures are ignored.
    public func revalidateIfNeeded() async {
        guard let activationService, case .active = state,
              let token = try? store.string(for: Keys.activation)
        else { return }
        if let last = try? store.date(for: Keys.lastValidated),
           now().timeIntervalSince(last) < Self.revalidationInterval {
            return
        }
        do {
            let revoked = try await activationService.isRevoked(activationToken: token)
            try store.setDate(now(), for: Keys.lastValidated)
            if revoked {
                try store.setString("1", for: Keys.revoked)
                Log.licensing.notice("License revoked")
            }
            refresh()
        } catch {
            Log.licensing.info("Re-validation skipped: \(String(describing: error), privacy: .public)")
        }
    }

    /// Handles `glint://activate?key=…`. Returns `true` when the URL was an activation link;
    /// the outcome is reflected in `state` and `lastError`.
    @discardableResult
    public func handle(url: URL) async -> Bool {
        guard let key = Self.activationKey(from: url) else { return false }
        try? await activate(key: key)
        return true
    }

    /// Extracts the key from an activation deep link.
    public nonisolated static func activationKey(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "glint", url.host?.lowercased() == "activate",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let key = components.queryItems?.first(where: { $0.name == "key" })?.value,
              !key.isEmpty
        else { return nil }
        return key
    }

    // MARK: - State

    private func apply(_ newState: LicenseState) {
        guard newState != state else { return }
        state = newState
        onChange?(entitlements)
    }

    /// Precedence: revoked, active license, running trial, seat limit, expired trial, none.
    private func computeState() -> LicenseState {
        if (try? store.string(for: Keys.revoked)) != nil { return .revoked }
        if let payload = verifiedActivation() { return .active(payload) }
        let trialStatus = (try? trial.status()) ?? .notStarted
        if case .active(let daysLeft, let endsAt) = trialStatus {
            return .trial(daysLeft: daysLeft, endsAt: endsAt)
        }
        if (try? store.string(for: Keys.seatLimit)) != nil { return .seatLimitReached }
        return trialStatus == .expired ? .trialExpired : .none
    }

    private func verifiedActivation() -> LicensePayload? {
        guard let token = try? store.string(for: Keys.activation),
              let installID = try? InstallID.current(in: store),
              let payload = try? verifier.verify(token, installID: installID)
        else { return nil }
        if payload.kind == .license, activationService != nil { return nil }
        return payload
    }
}

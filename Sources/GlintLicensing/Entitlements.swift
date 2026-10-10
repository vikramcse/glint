import Foundation
import GlintCore

/// Where the user stands with Glint Pro. Every state has designed UI.
public enum LicenseState: Sendable, Hashable {
    /// No trial yet and no license (only before the first launch completes).
    case none
    /// Pro trial running.
    case trial(daysLeft: Int, endsAt: Date)
    /// Trial over and no license.
    case trialExpired
    /// A verified Pro license.
    case active(LicensePayload)
    /// The license was refunded or charged back.
    case revoked
    /// Activation failed because every seat is in use.
    case seatLimitReached
}

/// The one place gating lives. Views and services ask `Entitlements` (or the
/// `FeatureGateSnapshot` it produces) and never inspect license state themselves.
public struct Entitlements: Sendable, Hashable {
    public let state: LicenseState

    public init(state: LicenseState) {
        self.state = state
    }

    /// Whether Pro features are unlocked (paid or in trial).
    public var isPro: Bool {
        switch state {
        case .trial, .active: true
        case .none, .trialExpired, .revoked, .seatLimitReached: false
        }
    }

    /// Whether the user has paid (as opposed to trialing).
    public var isLicensed: Bool {
        if case .active = state { true } else { false }
    }

    public var isTrial: Bool {
        if case .trial = state { true } else { false }
    }

    /// The gate handed to the indexer and search engine.
    public var snapshot: FeatureGateSnapshot { isPro ? .pro : .free }

    public func allows(_ feature: Feature) -> Bool { snapshot.allows(feature) }
    public func allows(_ kind: MediaKind) -> Bool { snapshot.allows(kind) }

    /// A trial is offered once, on first launch.
    public var canStartTrial: Bool { state == .none }

    /// Whether the license sheet should offer to enter a key.
    public var canActivate: Bool { !isLicensed }

    /// Whether Settings should offer "Deactivate this Mac".
    public var canDeactivate: Bool { isLicensed }

    /// Whether upgrade entry points (menu item, locked results) should be shown.
    public var showsUpgrade: Bool { !isLicensed }

    public var trialDaysLeft: Int? {
        if case .trial(let daysLeft, _) = state { daysLeft } else { nil }
    }

    /// The license payload when active.
    public var license: LicensePayload? {
        if case .active(let payload) = state { payload } else { nil }
    }
}

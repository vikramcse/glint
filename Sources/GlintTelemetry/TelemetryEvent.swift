import Foundation
import GlintCore

/// What opened the upgrade sheet.
public enum PaywallTrigger: String, Sendable, Hashable, CaseIterable {
    case itemLimit = "limit"
    case lockedResult = "locked_result"
    case menu
    case sourceLimit = "source_limit"
    case feature
}

/// The complete list of analytics events. Properties are bucketed by construction, so an
/// event can never carry query text, file names, paths, contents or vectors.
public enum TelemetryEvent: Sendable, Hashable {
    case appLaunched(AppLaunchInfo)
    case onboardingCompleted(sourceCount: Int, duration: TimeInterval)
    case firstSearch(minutesSinceInstall: Double)
    case indexProgress(itemsPerKind: [MediaKind: Int], pending: Int)
    case searchPerformed(latencyMilliseconds: Double, resultCount: Int, kinds: Set<MediaKind>)
    case resultOpened(rank: Int, kind: MediaKind)
    case paywallViewed(PaywallTrigger)
    case trialStarted
    case licenseActivated

    public var name: String {
        switch self {
        case .appLaunched: "app_launched"
        case .onboardingCompleted: "onboarding_completed"
        case .firstSearch: "first_search"
        case .indexProgress: "index_progress"
        case .searchPerformed: "search_performed"
        case .resultOpened: "result_opened"
        case .paywallViewed: "paywall_viewed"
        case .trialStarted: "trial_started"
        case .licenseActivated: "license_activated"
        }
    }

    /// Fraction of occurrences that are recorded. Search is sampled at 10%.
    public var sampleRate: Double {
        if case .searchPerformed = self { 0.1 } else { 1 }
    }

    /// Bucketed properties sent with the event.
    public var payload: [String: String] {
        switch self {
        case .appLaunched(let info):
            [
                "app_version": info.appVersion,
                "macos_version": info.macOSVersion,
                "chip_family": info.chipFamily,
                "ram": info.ramBucket,
            ]
        case .onboardingCompleted(let sourceCount, let duration):
            ["sources": TelemetryBuckets.count(sourceCount), "duration": TelemetryBuckets.duration(seconds: duration)]
        case .firstSearch(let minutes):
            ["since_install": TelemetryBuckets.sinceInstall(minutes: minutes)]
        case .indexProgress(let itemsPerKind, let pending):
            MediaKind.allCases.reduce(into: ["pending": TelemetryBuckets.count(pending)]) { result, kind in
                result["items_\(kind.rawValue)"] = TelemetryBuckets.count(itemsPerKind[kind] ?? 0)
            }
        case .searchPerformed(let latency, let resultCount, let kinds):
            [
                "latency": TelemetryBuckets.latency(milliseconds: latency),
                "results": TelemetryBuckets.count(resultCount),
                "media_types": kinds.isEmpty ? "none" : kinds.map(\.rawValue).sorted().joined(separator: ","),
            ]
        case .resultOpened(let rank, let kind):
            ["rank": TelemetryBuckets.rank(rank), "media_type": kind.rawValue]
        case .paywallViewed(let trigger):
            ["trigger": trigger.rawValue]
        case .trialStarted, .licenseActivated:
            [:]
        }
    }
}

/// The closed vocabulary of property values, used to prove redaction in tests and to drop
/// anything unexpected before an event is queued.
public enum TelemetrySchema {
    /// Returns `true` when every key and value of `payload` belongs to the event's schema.
    public static func isAllowed(name: String, payload: [String: String]) -> Bool {
        payload.allSatisfy { key, value in allowedValue(event: name, key: key, value: value) }
    }

    static func allowedValue(event: String, key: String, value: String) -> Bool {
        if let values = bucketValues["\(event).\(key)"] { return values.contains(value) }
        let kinds = Set(MediaKind.allCases.map(\.rawValue))
        switch (event, key) {
        case ("app_launched", "app_version"), ("app_launched", "macos_version"):
            return value == "unknown" || AppLaunchInfo.sanitizedVersion(value) == value
        case ("index_progress", _) where key.hasPrefix("items_"):
            return kinds.contains(String(key.dropFirst("items_".count))) && TelemetryBuckets.countValues.contains(value)
        case ("search_performed", "media_types"):
            return value == "none" || value.split(separator: ",").allSatisfy { kinds.contains(String($0)) }
        case ("result_opened", "media_type"):
            return kinds.contains(value)
        case ("paywall_viewed", "trigger"):
            return PaywallTrigger(rawValue: value) != nil
        default:
            return false
        }
    }

    /// Properties whose values come from a fixed set of buckets, keyed by "event.key".
    private static let bucketValues: [String: Set<String>] = [
        "app_launched.chip_family": Set(AppLaunchInfo.chipFamilies),
        "app_launched.ram": Set(TelemetryBuckets.ramValues),
        "onboarding_completed.sources": Set(TelemetryBuckets.countValues),
        "index_progress.pending": Set(TelemetryBuckets.countValues),
        "search_performed.results": Set(TelemetryBuckets.countValues),
        "onboarding_completed.duration": Set(TelemetryBuckets.durationValues),
        "first_search.since_install": Set(TelemetryBuckets.sinceInstallValues),
        "search_performed.latency": Set(TelemetryBuckets.latencyValues),
        "result_opened.rank": Set(TelemetryBuckets.rankValues),
    ]
}

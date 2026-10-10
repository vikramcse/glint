import Foundation

/// A capability that may be gated behind Pro. Views and services ask `FeatureGateSnapshot`,
/// which the licensing module's `Entitlements` produces; nothing checks license state directly.
public enum Feature: String, Sendable, Codable, CaseIterable, Hashable {
    case videoSearch
    case audioSearch
    case pdfVisualSearch
    case findSimilar
    case unlimitedItems
    case unlimitedSources
    case externalDrives
    case photosLibrary
    case fullFilters
    case savedSearches
    case modelChoice
    case localAPI
}

/// An immutable view of what the current user may do, cheap to pass across actors.
public struct FeatureGateSnapshot: Sendable, Hashable {
    public var enabled: Set<Feature>
    /// Maximum indexed items, or `nil` for unlimited.
    public var itemLimit: Int?
    /// Maximum source folders, or `nil` for unlimited.
    public var sourceLimit: Int?

    public init(enabled: Set<Feature>, itemLimit: Int?, sourceLimit: Int?) {
        self.enabled = enabled
        self.itemLimit = itemLimit
        self.sourceLimit = sourceLimit
    }

    public func allows(_ feature: Feature) -> Bool { enabled.contains(feature) }

    /// Whether results of `kind` can be opened (locked results stay visible but disabled).
    public func allows(_ kind: MediaKind) -> Bool {
        kind.requiredFeature.map(allows) ?? true
    }

    public static let freeItemLimit = 10_000
    public static let freeSourceLimit = 3

    public static let free = FeatureGateSnapshot(enabled: [], itemLimit: freeItemLimit, sourceLimit: freeSourceLimit)
    public static let pro = FeatureGateSnapshot(enabled: Set(Feature.allCases), itemLimit: nil, sourceLimit: nil)
}

/// A thread-safe source of the current feature gate, shared by services that must react to
/// license changes (the indexer, the search engine).
public final class FeatureGateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FeatureGateSnapshot

    public init(_ initial: FeatureGateSnapshot) { value = initial }

    public var current: FeatureGateSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func update(_ snapshot: FeatureGateSnapshot) {
        lock.lock()
        value = snapshot
        lock.unlock()
    }
}

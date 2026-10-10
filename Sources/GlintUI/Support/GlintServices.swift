import Foundation
import GlintCore
import GlintLicensing
import GlintSearch
import SwiftUI

/// Product events the UI reports. The app maps them to opt-in telemetry; the UI never
/// learns whether analytics are on, and nothing here carries query text or file names.
public enum UIEvent: Sendable, Hashable {
    case searchPerformed(latencyMilliseconds: Double, resultCount: Int, kinds: Set<MediaKind>)
    case resultOpened(rank: Int, kind: MediaKind)
    case paywallViewed(PaywallReason)
    case onboardingCompleted(sourceCount: Int, duration: TimeInterval)
}

/// Why the upgrade sheet was shown.
public enum PaywallReason: String, Sendable, Hashable {
    case itemLimit, lockedResult, menu, sourceLimit, feature
}

/// Actions on results that need AppKit (Quick Look panel, Finder, pasteboard, player windows).
/// Implemented by the app target, so views stay pure SwiftUI.
@MainActor
public protocol ResultActions: AnyObject {
    /// Opens the file, or the matched moment for video and audio.
    func open(_ result: SearchResult)
    func revealInFinder(_ results: [SearchResult])
    func quickLook(_ results: [SearchResult], selected: SearchResult?)
    func copy(_ results: [SearchResult])
    /// Dismisses the floating search panel (no-op in the main window).
    func dismissPanel()
    func showMainWindow()
    func showUpgrade(_ reason: PaywallReason)
    /// Opens the purchase page in the browser.
    func openPurchasePage()
    func openFullDiskAccessSettings()
    /// Shows the system folder picker and returns the chosen folders (empty when cancelled).
    /// AppKit's `NSOpenPanel` is used because SwiftUI's `fileImporter` does not present from
    /// AppKit-hosted windows or a menu bar agent.
    func chooseFolders(message: String, allowsMultipleSelection: Bool) -> [URL]
    /// Shows an alert with a user-facing message.
    func presentError(_ message: String)
}

/// Everything the views need, created once by the app's composition root.
@MainActor
public final class GlintServices {
    public let engine: SearchEngine
    public let indexing: any IndexingService
    public let license: LicenseManager
    public let settings: AppSettings
    public let status: IndexStatusModel
    public weak var actions: (any ResultActions)?
    public let report: @MainActor (UIEvent) -> Void
    /// Bytes on disk used by thumbnails and the database, for Settings > Models.
    public let storageUsage: @Sendable () async -> Int64
    /// The pending analytics payload, shown verbatim in Settings > Privacy.
    public let analyticsPreview: @Sendable () async -> String
    public let modelDescription: ModelDescription
    /// State of the local API for Settings › Privacy; `nil` hides the section. Set by the app.
    public var localAPI: LocalAPIControl?
    /// The search model's download and presets; `nil` in tests and previews.
    public var models: (any ModelControlling)?

    public init(
        engine: SearchEngine,
        indexing: any IndexingService,
        license: LicenseManager,
        settings: AppSettings,
        modelDescription: ModelDescription,
        report: @escaping @MainActor (UIEvent) -> Void,
        storageUsage: @escaping @Sendable () async -> Int64,
        analyticsPreview: @escaping @Sendable () async -> String
    ) {
        self.engine = engine
        self.indexing = indexing
        self.license = license
        self.settings = settings
        self.modelDescription = modelDescription
        self.report = report
        self.storageUsage = storageUsage
        self.analyticsPreview = analyticsPreview
        status = IndexStatusModel(indexing: indexing)
    }

    public var entitlements: Entitlements { license.entitlements }
}

/// Models offered in Settings > Models.
public struct ModelDescription: Sendable, Hashable {
    public struct Option: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var detail: String
        public var isAvailable: Bool
        public var isActive: Bool

        public init(id: String, name: String, detail: String, isAvailable: Bool, isActive: Bool) {
            self.id = id
            self.name = name
            self.detail = detail
            self.isAvailable = isAvailable
            self.isActive = isActive
        }
    }

    public var options: [Option]

    public init(options: [Option]) {
        self.options = options
    }
}

extension EnvironmentValues {
    @Entry public var glintServices: GlintServices?
}

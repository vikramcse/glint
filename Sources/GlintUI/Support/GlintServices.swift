import Foundation
import GlintCore
import GlintSearch
import SwiftUI

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
    public let settings: AppSettings
    public let status: IndexStatusModel
    public weak var actions: (any ResultActions)?
    /// In-app updates; `nil` in builds without an updater (development, tests).
    public weak var updates: (any UpdateChecking)?
    /// Bytes on disk used by thumbnails and the database, for Settings > Models.
    public let storageUsage: @Sendable () async -> Int64
    public let modelDescription: ModelDescription
    /// State of the local API for Settings › Privacy; `nil` hides the section. Set by the app.
    public var localAPI: LocalAPIControl?
    /// The search model's download and presets; `nil` in tests and previews.
    public var models: (any ModelControlling)?

    public init(
        engine: SearchEngine,
        indexing: any IndexingService,
        settings: AppSettings,
        modelDescription: ModelDescription,
        storageUsage: @escaping @Sendable () async -> Int64
    ) {
        self.engine = engine
        self.indexing = indexing
        self.settings = settings
        self.modelDescription = modelDescription
        self.storageUsage = storageUsage
        status = IndexStatusModel(indexing: indexing)
    }
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

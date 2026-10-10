import Foundation

/// In-app updates as the UI sees them. The app implements this with Sparkle; the UI never
/// imports the update framework.
@MainActor
public protocol UpdateChecking: AnyObject {
    /// Whether updates are configured for this build (signed release with a feed URL).
    var isAvailable: Bool { get }
    /// False while a check is already running.
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    /// Checks now and shows Sparkle's UI with the release notes when an update exists.
    func checkForUpdates()
}

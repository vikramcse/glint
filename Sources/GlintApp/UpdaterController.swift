import AppKit
import GlintUI
import Observation
import Sparkle

/// Sparkle 2 behind the UI's `UpdateChecking` protocol.
///
/// The updater starts only when Info.plist has an https `SUFeedURL` and an `SUPublicEDKey`,
/// so development builds (placeholders) never show Sparkle errors. Release notes come from
/// the appcast and appear in Sparkle's update window.
@MainActor
@Observable
final class UpdaterController: UpdateChecking {
    let isAvailable: Bool
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let userDriverDelegate = BackgroundAppUserDriverDelegate()
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(bundle: Bundle = .main) {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: userDriverDelegate
        )
        isAvailable = Self.isConfigured(bundle.infoDictionary ?? [:])
        guard isAvailable else { return }
        controller.startUpdater()
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        guard isAvailable else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    static func isConfigured(_ info: [String: Any]) -> Bool {
        guard let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)), feed.scheme == "https",
            let key = info["SUPublicEDKey"] as? String, !key.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
        return true
    }
}

/// Glint is a menu bar app, so scheduled update alerts use Sparkle's gentle reminders and
/// bring the app forward only when the user is shown an update.
private final class BackgroundAppUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState)
    {
        if handleShowingUpdate {
            DispatchQueue.main.async { NSApp.activate() }
        }
    }
}

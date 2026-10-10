import Foundation

/// Launch-time switches used by the UI test suite (`UITests/`). Never set in normal use.
///
/// - `GLINT_UI_TEST_ROOT`: isolated support folder and settings domain; also selects the
///   built-in model (no download), file-backed license storage and no local API.
/// - `GLINT_UI_TEST_SOURCE`: a folder added as a source at launch.
/// - `-GlintShowPanel`, `-GlintShowMainWindow`, `-GlintShowUpgrade`, `-GlintSkipOnboarding`.
struct LaunchOptions {
    let testRoot: URL?
    let testSource: URL?
    let showPanel: Bool
    let showMainWindow: Bool
    let showUpgrade: Bool
    let skipOnboarding: Bool

    static let current = LaunchOptions(environment: ProcessInfo.processInfo.environment, arguments: ProcessInfo.processInfo.arguments)

    init(environment: [String: String], arguments: [String]) {
        testRoot = environment["GLINT_UI_TEST_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        testSource = environment["GLINT_UI_TEST_SOURCE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        showPanel = arguments.contains("-GlintShowPanel")
        showMainWindow = arguments.contains("-GlintShowMainWindow")
        showUpgrade = arguments.contains("-GlintShowUpgrade")
        skipOnboarding = arguments.contains("-GlintSkipOnboarding")
    }

    var isUITest: Bool { testRoot != nil }

    /// A separate defaults domain so tests never read or write the user's settings.
    var defaults: UserDefaults {
        guard isUITest, let suite = UserDefaults(suiteName: "app.glint.mac.uitests") else { return .standard }
        return suite
    }
}

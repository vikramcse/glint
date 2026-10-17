import Foundation

/// Launch-time switches used by the UI test suite (`UITests/`). Never set in normal use.
///
/// - `GLINT_UI_TEST_ROOT`: isolated support folder and settings domain; also selects the
///   built-in model (no download) and no local API.
/// - `GLINT_UI_TEST_SOURCE`: a fixture folder, copied into the test root and added as a source at launch.
/// - `-GlintShowPanel`, `-GlintShowMainWindow`, `-GlintSkipOnboarding`.
/// - `-GlintUseInstalledModel`: with a test root, use EmbeddingGemma 2 from the test root's
///   `Models` folder instead of the built-in model (the README demo recording uses it).
struct LaunchOptions {
    let testRoot: URL?
    /// The copy of the fixture folder that Glint indexes (see `prepareUITest()`).
    let testSource: URL?
    let showPanel: Bool
    let showMainWindow: Bool
    let skipOnboarding: Bool
    let usesInstalledModel: Bool
    private let testFixtures: URL?

    static let current = LaunchOptions(environment: ProcessInfo.processInfo.environment, arguments: ProcessInfo.processInfo.arguments)
    private static let testSuite = "app.glint.mac.uitests"

    init(environment: [String: String], arguments: [String]) {
        let root = environment["GLINT_UI_TEST_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let fixtures = environment["GLINT_UI_TEST_SOURCE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        testRoot = root
        testFixtures = fixtures
        if let root, let fixtures {
            testSource = root.appendingPathComponent("Sources", isDirectory: true).appendingPathComponent(
                fixtures.lastPathComponent, isDirectory: true)
        } else {
            testSource = nil
        }
        showPanel = arguments.contains("-GlintShowPanel")
        showMainWindow = arguments.contains("-GlintShowMainWindow")
        skipOnboarding = arguments.contains("-GlintSkipOnboarding")
        usesInstalledModel = arguments.contains("-GlintUseInstalledModel")
    }

    var isUITest: Bool { testRoot != nil }

    /// A separate defaults domain so tests never read or write the user's settings.
    var defaults: UserDefaults {
        guard isUITest, let suite = UserDefaults(suiteName: Self.testSuite) else { return .standard }
        return suite
    }

    /// Starts each UI test from empty settings and copies the fixture folder into the test root.
    /// The test runner is sandboxed, so it can't do either itself: it can't reach Glint's settings,
    /// and it can only write inside its own container, which Glint never indexes.
    func prepareUITest() throws {
        guard isUITest else { return }
        defaults.removePersistentDomain(forName: Self.testSuite)
        guard let testFixtures, let testSource else { return }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: testSource)
        try fileManager.createDirectory(at: testSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: testFixtures, to: testSource)
    }
}

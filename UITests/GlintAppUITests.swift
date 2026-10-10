import XCTest

/// Click-through tests of the real app. Each test launches Glint against an isolated support
/// folder and settings domain (see Sources/GlintApp/LaunchOptions.swift), with a small source
/// folder of text files, so nothing touches the user's index, settings or keychain.
@MainActor
final class GlintAppUITests: XCTestCase {
    private var root: URL!
    private var source: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("glint-ui-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "Flight confirmation IndiGo 6E 2341, BLR to GOI, booking ref QX7P2M".write(
            to: source.appendingPathComponent("flight-confirmation.txt"), atomically: true, encoding: .utf8)
        try "Weeknight pasta sauce with tomatoes, garlic and basil".write(
            to: source.appendingPathComponent("pasta.txt"), atomically: true, encoding: .utf8)
        UserDefaults(suiteName: "app.glint.mac.uitests")?.removePersistentDomain(forName: "app.glint.mac.uitests")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["GLINT_UI_TEST_ROOT"] = root.appendingPathComponent("Support").path
        app.launchEnvironment["GLINT_UI_TEST_SOURCE"] = source.path
        app.launchArguments = arguments
        app.launch()
        return app
    }

    func testOnboardingAddsTheSuggestedFolderAndOpensSearch() {
        let app = launch([])
        let window = app.windows["Welcome to Glint"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.buttons["onboarding.continue"].click()
        XCTAssertTrue(window.checkBoxes["Library"].waitForExistence(timeout: 5), "the fixture folder is suggested")
        window.buttons["onboarding.continue"].click()
        window.buttons["onboarding.start"].click()
        XCTAssertTrue(app.textFields["panel.search"].waitForExistence(timeout: 10), "search opens after onboarding")
        XCTAssertFalse(window.exists)
    }

    func testPanelFindsAFileByWhatItSays() {
        let app = launch(["-GlintSkipOnboarding", "-GlintShowPanel"])
        let field = app.textFields["panel.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("booking ref")
        let result = app.descendants(matching: .any)["result.flight-confirmation.txt"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))

        // Esc clears the query first.
        field.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(field.value as? String ?? "", "")
    }

    func testMainWindowSearchesTheLibrary() {
        let app = launch(["-GlintSkipOnboarding", "-GlintShowMainWindow"])
        let window = app.windows["Glint"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(window.staticTexts["All Items"].waitForExistence(timeout: 5))
        let search = window.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("pasta")
        XCTAssertTrue(window.staticTexts["pasta.txt"].waitForExistence(timeout: 15))
    }

    func testUpgradeSheetRejectsAnInvalidKey() {
        let app = launch(["-GlintSkipOnboarding", "-GlintShowUpgrade"])
        let window = app.windows["Glint Pro"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(window.buttons["upgrade.buy"].exists)
        let key = window.textFields["upgrade.key"]
        key.click()
        key.typeText("not-a-key")
        window.buttons["upgrade.activate"].click()
        XCTAssertTrue(window.staticTexts["upgrade.message"].waitForExistence(timeout: 5))
        window.buttons["upgrade.notNow"].click()
        XCTAssertFalse(window.waitForExistence(timeout: 2))
    }

    func testSettingsShowsEveryTab() {
        let app = launch(["-GlintSkipOnboarding", "-GlintShowMainWindow"])
        XCTAssertTrue(app.windows["Glint"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.toolbarButton, identifier: "General").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        for tab in ["General", "Sources", "Search", "Models", "Privacy", "License"] {
            XCTAssertTrue(settings.toolbarButtons[tab].exists, "missing tab \(tab)")
        }
        settings.toolbarButtons["Sources"].click()
        XCTAssertTrue(settings.buttons["Add Folder…"].waitForExistence(timeout: 5))
    }
}

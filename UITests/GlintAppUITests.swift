import XCTest

/// Click-through tests of the real app. Each test launches Glint against an isolated support
/// folder and settings domain (see Sources/GlintApp/LaunchOptions.swift), with a small source
/// folder of text files, so nothing touches the user's index, settings or keychain.
///
/// The runner is sandboxed: it can only write inside its own container, which Glint never
/// indexes. So the test root sits in /private/tmp (Glint creates it) and the fixtures ship in
/// this bundle; Glint copies them into the test root and resets its test settings at launch.
@MainActor
final class GlintAppUITests: XCTestCase {
    private var root: URL!
    private var fixtures: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            "glint-ui-\(UUID().uuidString)", isDirectory: true)
        fixtures = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Library", withExtension: nil))
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["GLINT_UI_TEST_ROOT"] = root.path
        app.launchEnvironment["GLINT_UI_TEST_SOURCE"] = fixtures.path
        // Legacy scroll bars, as on CI's virtual Macs (a mouse, no trackpad): they take width from
        // scrolling content, which once sent the panel into an endless resize.
        app.launchArguments = arguments + ["-AppleShowScrollBars", "Always"]
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
        let window = app.windows["main"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(window.staticTexts["All Items"].waitForExistence(timeout: 5))
        let search = window.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("pasta")
        XCTAssertTrue(window.staticTexts["pasta.txt"].waitForExistence(timeout: 15))
    }

    func testSettingsShowsEveryTab() {
        let app = launch(["-GlintSkipOnboarding", "-GlintShowMainWindow"])
        XCTAssertTrue(app.windows["main"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        // The title follows the selected tab; the tabs are plain buttons in the toolbar.
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let tabs = settings.toolbars.firstMatch
        for tab in ["General", "Sources", "Search", "Models", "Privacy"] {
            XCTAssertTrue(tabs.buttons[tab].exists, "missing tab \(tab)")
        }
        tabs.buttons["Sources"].click()
        XCTAssertTrue(settings.descendants(matching: .any)["sources.add"].waitForExistence(timeout: 5))
    }
}

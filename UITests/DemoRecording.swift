import XCTest

/// Records the main-window part of the README demo video (`scripts/demo-video`): drives the real
/// app over a demo library with EmbeddingGemma 2 and screenshots the window at every step.
///
/// Skipped unless `GLINT_DEMO_ROOT` (a support folder whose `Models` holds the installed model)
/// and `GLINT_DEMO_SOURCE` (the demo library) are set; pass them to xcodebuild with the
/// `TEST_RUNNER_` prefix. Frames and `frames.json` land in the runner's temporary folder, whose
/// path is printed.
///
/// A window screenshot captures whatever is on screen in the window's frame, so the app is
/// activated before every frame and a frame is skipped unless Glint is frontmost. Keep the Mac
/// hands-off while it runs: the test types into Glint.
@MainActor
final class DemoRecording: XCTestCase {
    private struct Frame: Encodable {
        var file: String
        var step: String
        var milliseconds: Int
    }

    private var frames: [Frame] = []
    private var output: URL!
    private var start = Date()

    func testRecordsMainWindow() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["GLINT_DEMO_ROOT"], let source = environment["GLINT_DEMO_SOURCE"] else {
            throw XCTSkip("Set GLINT_DEMO_ROOT and GLINT_DEMO_SOURCE to record the demo")
        }
        output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("glint-demo-frames", isDirectory: true)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let app = XCUIApplication()
        app.launchEnvironment["GLINT_UI_TEST_ROOT"] = root
        app.launchEnvironment["GLINT_UI_TEST_SOURCE"] = source
        app.launchArguments = ["-GlintSkipOnboarding", "-GlintShowMainWindow", "-GlintUseInstalledModel"]
        app.launch()
        app.activate()
        let window = app.windows["main"]
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        // The demo library indexes in about 10 s; give the model load and thumbnails time too.
        sleep(UInt32(environment["GLINT_DEMO_WAIT"].flatMap(UInt32.init) ?? 45))
        start = Date()

        app.activate()
        capture(window, "library", holds: 3)
        window.outlines.staticTexts["Photos"].click()
        capture(window, "photos", holds: 3)
        window.outlines.staticTexts["All Items"].click()
        capture(window, "all")

        search(window, "red car parked under trees", select: "IMG_4657.jpg")
        search(window, "noodle soup", select: "IMG_1791.jpg")
        search(window, "pricing slide", select: "Acme pitch.pdf")

        let manifest = try JSONEncoder().encode(frames)
        try manifest.write(to: output.appendingPathComponent("frames.json"))
        print("DEMO_FRAMES \(output.path)")
    }

    private func search(_ window: XCUIElement, _ text: String, select name: String) {
        let field = window.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        capture(window, "clear")
        for character in text {
            field.typeText(String(character))
            capture(window, "type")
        }
        // Semantic results merge in after the query is embedded.
        sleep(3)
        capture(window, "results", holds: 2)
        let result = window.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        if result.exists {
            result.click()
            usleep(600_000)
        }
        capture(window, "selected", holds: 3)
    }

    /// Screenshots the window `holds` times, so a still moment has more than one frame.
    private func capture(_ window: XCUIElement, _ step: String, holds: Int = 1) {
        let app = XCUIApplication()
        if app.state != .runningForeground { app.activate() }
        guard app.state == .runningForeground else { return }
        for _ in 0..<holds {
            let file = String(format: "%04d.png", frames.count)
            try? window.screenshot().pngRepresentation.write(to: output.appendingPathComponent(file))
            frames.append(Frame(file: file, step: step, milliseconds: Int(Date().timeIntervalSince(start) * 1_000)))
        }
    }
}

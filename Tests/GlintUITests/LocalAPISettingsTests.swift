import Foundation
import Testing

@testable import GlintUI

@MainActor
@Suite("Local API settings")
struct LocalAPISettingsTests {
    @Test func toggleIsOffByDefaultAndPersists() throws {
        let suite = "glint-localapi-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.localAPIEnabled)
        settings.localAPIEnabled = true
        #expect(AppSettings(defaults: defaults).localAPIEnabled)
    }

    @Test func statusTextIsHonest() {
        #expect(LocalAPIDisplayStatus.off.text == "Off")
        #expect(LocalAPIDisplayStatus.running(port: 52_341).text == "On · 127.0.0.1:52341 · this Mac only")
        #expect(LocalAPIDisplayStatus.failed("Port in use").text == "Port in use")
    }
}

import Foundation
import GlintCore
import GlintLicensing
import GlintSearch
import Testing

@testable import GlintUI

@Suite("Formatting and accessibility")
struct PresentationTests {
    @Test func timecodes() {
        #expect(Formatting.timecode(0) == "0:00")
        #expect(Formatting.timecode(724.9) == "12:04")
        #expect(Formatting.timecode(3_729) == "1:02:09")
    }

    @Test func locationsForPagesAndMoments() {
        #expect(Formatting.location(of: .page(3)) == "Page 4")
        #expect(Formatting.location(of: .time(start: 61, end: 66)) == "1:01")
        #expect(Formatting.location(of: .whole) == nil)
    }

    @Test func voiceOverLabelForVideoMoment() {
        let result = SearchResult.fixture(name: "Beach trip.mov", kind: .video, locator: .time(start: 724, end: 729))
        #expect(AccessibilityText.label(for: result) == "Video, Beach trip, moment at 12 minutes, 4 seconds")
    }

    @Test func voiceOverLabelMentionsLockAndPage() {
        var result = SearchResult.fixture(name: "deck.pdf", kind: .pdf, locator: .page(1))
        result.isLocked = true
        #expect(AccessibilityText.label(for: result) == "PDF, deck, page 2, requires Glint Pro")
    }

    @Test func keyComboDisplay() {
        #expect(KeyCombo.defaultSearch.displayString == "⌥Space")
        #expect(KeyCombo(keyCode: 3, command: true, shift: true).displayString == "⇧⌘F")
        #expect(!KeyCombo(keyCode: 3).hasModifier)
    }

    @Test func errorsMapToUserMessages() {
        #expect(ErrorPresenter.message(for: EntitlementError.sourceLimitReached(limit: 3)).contains("3 folders"))
        #expect(ErrorPresenter.message(for: LicenseError.seatLimitReached).contains("2 Macs"))
        #expect(ErrorPresenter.message(for: CocoaError(.fileReadNoPermission)).contains("permission"))
        #expect(ErrorPresenter.message(for: CancellationError()) == "Cancelled.")
    }

    @MainActor
    @Test func settingsPersist() throws {
        let suite = "glint-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.hotKey == .defaultSearch)
        #expect(settings.groupResultsByKind)
        settings.hotKey = KeyCombo(keyCode: 49, command: true)
        settings.defaultKinds = [.pdf]
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.hotKey.command)
        #expect(reloaded.defaultKinds == [.pdf])
        #expect(reloaded.installDate == settings.installDate)
    }
}

extension SearchResult {
    static func fixture(name: String, kind: MediaKind, locator: ChunkLocator = .whole, waveform: [Float]? = nil, snippet: String? = nil)
        -> SearchResult
    {
        SearchResult(
            file: FileSummary(
                id: FileID(Int64(abs(name.hashValue % 10_000))), name: name, path: "/Users/demo/Library/\(name)", kind: kind,
                modified: Date(timeIntervalSinceNow: -3_600), size: 4_200_000, duration: kind == .video || kind == .audio ? 1_800 : nil,
                waveform: waveform, isIndexed: true
            ),
            match: MatchDetail(
                chunkID: nil, locator: locator,
                snippet: snippet.map { Snippet.make(from: $0, terms: ["pricing", "deadline"]) }, thumbnailURL: nil
            ),
            score: 1, sources: [.semantic], isLocked: false
        )
    }
}

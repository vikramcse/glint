import Foundation
import GlintCore
import GlintLicensing
import GlintSearch
import GlintStore
import GlintTestSupport
import Testing
import UniformTypeIdentifiers

@testable import GlintUI

/// Maps a few queries to fixed directions so semantic results are deterministic.
private struct TableEncoder: QueryEncoding {
    let space: VectorSpace
    var delay: Duration = .zero

    func encode(query: String) async throws -> Embedding {
        try await Task.sleep(for: delay)
        var values = [Float](repeating: 0, count: space.dimension)
        values[query.contains("beach") ? 0 : 3] = 1
        return Embedding(normalizing: values, space: space)
    }
}

/// A small indexed library: one file per kind plus extra documents for grouping.
@MainActor
func makeEngine(encoderDelay: Duration = .zero, gate: FeatureGateSnapshot = .pro) async throws -> (SearchEngine, TemporaryDirectory) {
    let directory = try TemporaryDirectory(prefix: "glint-ui")
    let url = directory.url.appendingPathComponent("index.sqlite")
    let space = VectorSpace(modelID: "ui/1", dimension: 4)
    let writer = try IndexWriter(url: url)
    let source = try await writer.addSource(path: "/lib", bookmark: nil)
    let corpus: [(String, MediaKind, String, Int)] = [
        ("beach.jpg", .image, "sunny beach", 0),
        ("Beach trip.mov", .video, "waves at the beach", 0),
        ("memo.m4a", .audio, "beach plans", 1),
        ("deck.pdf", .pdf, "beach resort pricing", 2),
        ("notes.md", .document, "beach packing list", 3),
        ("todo.txt", .document, "beach umbrella", 3),
    ]
    _ = try await writer.reconcile(
        sourceID: source,
        scanned: corpus.map {
            ScannedFile(path: "/lib/\($0.0)", kind: $0.1, contentType: .data, size: 1, modified: Date())
        })
    for record in try await writer.claimPending(limit: 10, kinds: Set(MediaKind.allCases)) {
        guard let entry = corpus.first(where: { $0.0 == record.name }) else { continue }
        var vector = [Float](repeating: 0, count: 4)
        vector[entry.3] = 1
        let locator: ChunkLocator = entry.1 == .video ? .time(start: 724, end: 729) : .whole
        _ = try await writer.commit(
            fileID: record.id, contentHash: record.name, space: space,
            chunks: [
                ChunkWrite(ordinal: 0, locator: locator, text: entry.2, thumbnail: nil, vector: vector)
            ])
    }
    let engine = SearchEngine(
        reader: try IndexReader(url: url), vectorIndex: FlatVectorIndex(space: space, useGPU: false),
        encoder: TableEncoder(space: space, delay: encoderDelay),
        thumbnails: ThumbnailStore(directory: directory.url), gate: FeatureGateBox(gate)
    )
    try await engine.loadVectors()
    return (engine, directory)
}

@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Suite("SearchModel")
struct SearchModelTests {
    @Test func keywordResultsArriveThenMergedResults() async throws {
        let (engine, directory) = try await makeEngine(encoderDelay: .milliseconds(150))
        _ = directory
        var events: [UIEvent] = []
        let model = SearchModel(
            engine: engine, entitlements: { Entitlements(state: .trial(daysLeft: 3, endsAt: .now)) }, report: { events.append($0) })
        model.text = "beach"
        await waitUntil { model.phase == .keyword }
        #expect(model.phase == .keyword)
        #expect(!model.results.isEmpty)
        await waitUntil { model.phase == .merged }
        #expect(model.phase == .merged)
        #expect(!model.isMerging)
        #expect(events.contains { if case .searchPerformed = $0 { true } else { false } })
    }

    @Test func newKeystrokeCancelsInFlightMerge() async throws {
        let (engine, directory) = try await makeEngine(encoderDelay: .milliseconds(200))
        _ = directory
        let model = SearchModel(engine: engine, entitlements: { Entitlements(state: .trialExpired) })
        model.text = "beach"
        try await Task.sleep(for: .milliseconds(60))
        model.text = "packing"
        await waitUntil { model.phase == .merged }
        #expect(model.currentQuery.text == "packing")
        #expect(model.results.first?.file.name == "notes.md")
    }

    @Test func selectionStaysPutWhenResultsMerge() async throws {
        let (engine, directory) = try await makeEngine(encoderDelay: .milliseconds(150))
        _ = directory
        let model = SearchModel(engine: engine, entitlements: { Entitlements(state: .trial(daysLeft: 3, endsAt: .now)) })
        model.groupByKind = false
        model.text = "beach"
        await waitUntil { model.phase == .keyword }
        model.moveSelection(by: 2)
        let pinned = model.selection
        let pinnedIndex = model.displayOrder.firstIndex { $0.id == pinned }
        await waitUntil { model.phase == .merged }
        #expect(model.selection == pinned)
        #expect(model.displayOrder.firstIndex { $0.id == pinned } == pinnedIndex)
    }

    @Test func groupsTopHitsThenKindsAndWalksInDisplayOrder() async throws {
        let (engine, directory) = try await makeEngine()
        _ = directory
        let model = SearchModel(engine: engine, entitlements: { Entitlements(state: .trial(daysLeft: 3, endsAt: .now)) })
        model.text = "beach"
        await waitUntil { model.phase == .merged }
        let sections = model.sections
        #expect(sections.first?.kind == .topHits)
        #expect(sections.first?.results.count == 3)
        #expect(sections.dropFirst().allSatisfy { if case .media = $0.kind { true } else { false } })

        model.moveSelection(by: -10)
        #expect(model.selection == model.displayOrder.first?.id)
        model.moveSelection(by: 100)
        #expect(model.selection == model.displayOrder.last?.id)
        #expect(model.rank(of: model.displayOrder[1]) == 2)
    }

    @Test func freeTierIgnoresProFiltersButKeepsKindFilters() async throws {
        let (engine, directory) = try await makeEngine(gate: .free)
        _ = directory
        let model = SearchModel(engine: engine, entitlements: { Entitlements(state: .trialExpired) })
        model.text = "beach kind:pdf in:Elsewhere"
        #expect(model.currentQuery.filter.kinds == [.pdf])
        #expect(model.currentQuery.filter.folders.isEmpty)
        await waitUntil { model.phase == .merged }
        #expect(model.results.map(\.file.name) == ["deck.pdf"])
    }

    @Test func sidebarFolderScopesSearchOnEveryTier() async throws {
        let (engine, directory) = try await makeEngine(gate: .free)
        _ = directory
        let model = SearchModel(engine: engine, entitlements: { Entitlements(state: .trialExpired) })
        model.folderScope = "/elsewhere"
        model.text = "beach"
        #expect(model.currentQuery.filter.folders == ["/elsewhere"])
        await waitUntil { model.phase == .merged }
        #expect(model.results.isEmpty)

        model.folderScope = "/lib"
        await waitUntil { model.phase == .merged && !model.results.isEmpty }
        #expect(model.results.count == 6)
    }

    @Test func lockedResultsAreVisibleOnFree() async throws {
        let (engine, directory) = try await makeEngine(gate: .free)
        _ = directory
        let model = SearchModel(engine: engine, entitlements: { Entitlements(state: .trialExpired) })
        model.text = "waves"
        await waitUntil { model.phase == .merged }
        let video = try #require(model.results.first { $0.file.kind == .video })
        #expect(video.isLocked)
    }

    @Test func emptyStatesAreHonest() async throws {
        let (engine, directory) = try await makeEngine()
        _ = directory
        let model = SearchModel(engine: engine, entitlements: { Entitlements(state: .trialExpired) })
        #expect(model.emptyState(status: IndexStatus(sourceCount: 0)) == .noSources)
        #expect(model.emptyState(status: IndexStatus(sourceCount: 1)) == .start)
        model.text = "zzzz qqqq kind:audio"
        await waitUntil { model.phase == .merged || !model.isMerging }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.emptyState(status: IndexStatus(pending: 12, sourceCount: 1)) == .stillIndexing(pending: 12))
        #expect(model.emptyState(status: IndexStatus(locked: 3, sourceCount: 1)) == .noResults(lockedKinds: true))
    }

    @Test func droppedFileShowsSimilarResultsEvenAfterTyping() async throws {
        let (engine, directory) = try await makeEngine()
        _ = directory
        let model = SearchModel(engine: engine, entitlements: { Entitlements(state: .trial(daysLeft: 3, endsAt: .now)) })
        model.text = "beach"
        await waitUntil { model.phase == .merged }
        model.findSimilar(toFileAt: URL(fileURLWithPath: "/lib/beach.jpg"))
        await waitUntil { !model.isMerging }
        #expect(model.text.isEmpty)
        #expect(model.isFindingSimilar)
        #expect(model.similarExampleName == "beach.jpg")
        #expect(model.results.map(\.file.name).contains("Beach trip.mov"))
        #expect(!model.results.map(\.file.name).contains("beach.jpg"))

        model.clear()
        #expect(!model.isFindingSimilar)
    }

    @Test func droppedFileThatCannotBeReadSaysSo() async throws {
        let (engine, directory) = try await makeEngine()
        _ = directory
        let model = SearchModel(engine: engine, entitlements: { Entitlements(state: .trial(daysLeft: 3, endsAt: .now)) })
        model.findSimilar(toFileAt: URL(fileURLWithPath: "/elsewhere/holiday.jpg"))
        await waitUntil { !model.isMerging }
        guard case .failed = model.emptyState(status: IndexStatus(sourceCount: 1)) else {
            Issue.record("Expected a failure state, got \(String(describing: model.emptyState(status: IndexStatus(sourceCount: 1))))")
            return
        }
    }

    @Test func findSimilarRequiresPro() async throws {
        let (engine, directory) = try await makeEngine()
        _ = directory
        let model = SearchModel(engine: engine, entitlements: { Entitlements(state: .trialExpired) })
        model.text = "beach"
        await waitUntil { model.phase == .merged }
        let first = try #require(model.results.first)
        model.findSimilar(to: first)
        #expect(model.similarTo == nil)
    }
}

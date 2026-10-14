import Foundation
import GlintCore
import GlintStore
import Testing
import UniformTypeIdentifiers

@testable import GlintSearch

/// Maps known queries to fixed directions so engine tests are deterministic.
private struct FakeEncoder: QueryEncoding {
    let space: VectorSpace
    let table: [String: Int]
    var mixed: [String: [Float]] = [:]
    var limitsLooseKeywords = false

    func encode(query: String) async throws -> Embedding {
        if let values = mixed[query] { return Embedding(normalizing: values, space: space) }
        var values = [Float](repeating: 0, count: space.dimension)
        values[table[query] ?? (space.dimension - 1)] = 1
        return Embedding(normalizing: values, space: space)
    }
}

private struct Harness {
    let engine: SearchEngine
    let writer: IndexWriter
    let ids: [String: FileID]

    static func make(limitsLooseKeywords: Bool = false) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glint-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("index.sqlite")
        let space = VectorSpace(modelID: "fake/1", dimension: 8)
        let writer = try IndexWriter(url: url)
        let source = try await writer.addSource(path: "/lib", bookmark: nil)

        // name, kind, text, direction
        let corpus: [(String, MediaKind, String?, Int)] = [
            ("beach.jpg", .image, nil, 0),
            ("Acme pitch.pdf", .pdf, "Pricing chart showing revenue by region", 1),
            ("standup.m4a", .audio, "the client mentioned the deadline is friday", 2),
            ("notes.md", .document, "Flight confirmation ABC123 for Goa", 3),
        ]
        _ = try await writer.reconcile(
            sourceID: source,
            scanned: corpus.map { name, kind, _, _ in
                ScannedFile(path: "/lib/\(name)", kind: kind, contentType: .data, size: 1, modified: Date(timeIntervalSince1970: 1_000))
            })
        let claimed = try await writer.claimPending(limit: 10, kinds: Set(MediaKind.allCases))
        var ids: [String: FileID] = [:]
        for record in claimed {
            guard let entry = corpus.first(where: { $0.0 == record.name }) else { continue }
            var vector = [Float](repeating: 0, count: 8)
            vector[entry.3] = 1
            _ = try await writer.commit(
                fileID: record.id, contentHash: record.name, space: space,
                chunks: [
                    ChunkWrite(ordinal: 0, locator: .whole, text: entry.2, thumbnail: "th/\(record.name).jpg", vector: vector)
                ])
            ids[record.name] = record.id
        }

        let engine = SearchEngine(
            reader: try IndexReader(url: url),
            vectorIndex: FlatVectorIndex(space: space, useGPU: false),
            encoder: FakeEncoder(
                space: space, table: ["dog on the sand": 0, "when was the deadline": 2],
                // Closer to the standup than to the pitch, which has the word "revenue".
                mixed: ["revenue lunch": [0, 0.6, 0.8, 0, 0, 0, 0, 0]], limitsLooseKeywords: limitsLooseKeywords),
            thumbnails: ThumbnailStore(directory: directory.appendingPathComponent("Thumbnails"))
        )
        #expect(try await engine.loadVectors() == 4)
        return Harness(engine: engine, writer: writer, ids: ids)
    }
}

@Suite("SearchEngine")
struct SearchEngineTests {
    @Test(arguments: [false, true])
    func partialKeywordMatchesBoostOnlyWithAWeakerModel(limits: Bool) async throws {
        let harness = try await Harness.make(limitsLooseKeywords: limits)
        let results = try await harness.engine.mergedResults(for: SearchQuery(text: "revenue lunch"))
        // The built-in model needs the partial match on "revenue" to lift the pitch; with a
        // model that limits partial matches, they only add files and the semantic order holds.
        #expect(results.items.first?.file.name == (limits ? "standup.m4a" : "Acme pitch.pdf"))
    }

    @Test func keywordPhaseFindsTextAndNames() async throws {
        let harness = try await Harness.make()
        let byText = try await harness.engine.keywordResults(for: SearchQuery(text: "flight confirm"))
        #expect(byText.phase == .keyword)
        #expect(byText.items.first?.file.name == "notes.md")
        #expect(byText.items.first?.match.snippet?.highlights.isEmpty == false)

        let byName = try await harness.engine.keywordResults(for: SearchQuery(text: "acme"))
        #expect(byName.items.first?.file.name == "Acme pitch.pdf")
        #expect(byName.items.first?.sources.contains(.name) == true)
    }

    @Test func mergedPhaseAddsSemanticMatches() async throws {
        let harness = try await Harness.make()
        let keyword = try await harness.engine.keywordResults(for: SearchQuery(text: "dog on the sand"))
        #expect(keyword.items.isEmpty)
        let merged = try await harness.engine.mergedResults(for: SearchQuery(text: "dog on the sand"))
        #expect(merged.items.first?.file.name == "beach.jpg")
        #expect(merged.items.first?.match.thumbnailURL?.lastPathComponent == "beach.jpg.jpg")
    }

    @Test func naturalLanguageFallsBackToAnyTerm() async throws {
        let harness = try await Harness.make()
        let results = try await harness.engine.keywordResults(for: SearchQuery(text: "chart for the quarterly board"))
        #expect(results.items.first?.file.name == "Acme pitch.pdf")
    }

    @Test func filtersApplyToBothPhases() async throws {
        let harness = try await Harness.make()
        let query = SearchQuery(text: "when was the deadline", filter: SearchFilter(kinds: [.image]))
        let results = try await harness.engine.mergedResults(for: query)
        #expect(results.items.allSatisfy { $0.file.kind == .image })
    }

    @Test func similarExcludesTheExample() async throws {
        let harness = try await Harness.make()
        let beach = try #require(harness.ids["beach.jpg"])
        let results = try await harness.engine.similar(to: beach)
        #expect(!results.items.contains { $0.id == beach })
    }

    @Test func libraryListsRecentFilesByKind() async throws {
        let harness = try await Harness.make()
        let pdfs = try await harness.engine.recent(kinds: [.pdf], limit: 10)
        #expect(pdfs.map(\.file.name) == ["Acme pitch.pdf"])
    }

    @Test func emptyQueryReturnsNothing() async throws {
        let harness = try await Harness.make()
        #expect(try await harness.engine.mergedResults(for: SearchQuery(text: "  ")).items.isEmpty)
    }
}

import CoreGraphics
import Foundation
import GlintCore
import Testing
import UniformTypeIdentifiers

@testable import GlintStore

private func makeDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glint-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("index.sqlite")
}

private func scanned(_ path: String, kind: MediaKind = .document, size: Int64 = 10, modified: TimeInterval = 1_000) -> ScannedFile {
    ScannedFile(path: path, kind: kind, contentType: kind == .document ? .plainText : .png, size: size,
                modified: Date(timeIntervalSince1970: modified))
}

private let space = VectorSpace(modelID: "test/1", dimension: 4)

@Suite("IndexWriter")
struct IndexWriterTests {
    @Test func reconcileAddsChangesAndRemoves() async throws {
        let writer = try IndexWriter(url: try makeDatabaseURL())
        let source = try await writer.addSource(path: "/s", bookmark: nil)

        var result = try await writer.reconcile(sourceID: source, scanned: [scanned("/s/a.txt"), scanned("/s/b.txt")])
        #expect(result.added == 2)

        result = try await writer.reconcile(sourceID: source, scanned: [scanned("/s/a.txt", size: 11)])
        #expect(result.added == 0)
        #expect(result.changed == 1)
        #expect(result.removed.count == 1)

        let counts = try await writer.counts()
        #expect(counts.pending[.document] == 1)
    }

    @Test func scopedReconcileOnlyTouchesScope() async throws {
        let writer = try IndexWriter(url: try makeDatabaseURL())
        let source = try await writer.addSource(path: "/s", bookmark: nil)
        _ = try await writer.reconcile(sourceID: source, scanned: [scanned("/s/x/a.txt"), scanned("/s/y/b.txt")])
        let result = try await writer.reconcile(sourceID: source, scanned: [], scope: "/s/x")
        #expect(result.removed.count == 1)
        #expect(try await writer.counts().totalPending == 1)
    }

    @Test func claimOrdersByPriorityThenRecency() async throws {
        let writer = try IndexWriter(url: try makeDatabaseURL())
        let source = try await writer.addSource(path: "/s", bookmark: nil)
        _ = try await writer.reconcile(sourceID: source, scanned: [
            scanned("/s/old.txt", modified: 100),
            scanned("/s/new.txt", modified: 200),
            ScannedFile(path: "/s/clip.mov", kind: .video, contentType: .quickTimeMovie, size: 1, modified: Date(timeIntervalSince1970: 300)),
        ])
        let claimed = try await writer.claimPending(limit: 10, kinds: Set(MediaKind.allCases))
        #expect(claimed.map(\.name) == ["new.txt", "old.txt", "clip.mov"])

        let gated = try await writer.claimPending(limit: 10, kinds: [.image])
        #expect(gated.isEmpty)
    }

    @Test func exhaustedFilesFail() async throws {
        let writer = try IndexWriter(url: try makeDatabaseURL())
        let source = try await writer.addSource(path: "/s", bookmark: nil)
        _ = try await writer.reconcile(sourceID: source, scanned: [scanned("/s/crashy.txt")])
        for _ in 0..<IndexWriter.maxAttempts {
            #expect(try await writer.claimPending(limit: 1, kinds: [.document]).count == 1)
        }
        #expect(try await writer.claimPending(limit: 1, kinds: [.document]).isEmpty)
        #expect(try await writer.failExhausted() == 1)
        #expect(try await writer.counts().failed == 1)
    }

    @Test func commitReplacesChunksAndDeduplicates() async throws {
        let url = try makeDatabaseURL()
        let writer = try IndexWriter(url: url)
        let source = try await writer.addSource(path: "/s", bookmark: nil)
        _ = try await writer.reconcile(sourceID: source, scanned: [scanned("/s/a.txt"), scanned("/s/copy.txt")])
        let files = try await writer.claimPending(limit: 2, kinds: [.document])
        let original = try #require(files.first { $0.name == "a.txt" })
        let copy = try #require(files.first { $0.name == "copy.txt" })

        let chunks = [
            ChunkWrite(ordinal: 0, locator: .text(start: 0, end: 5), text: "hello world", thumbnail: nil, vector: [1, 0, 0, 0]),
            ChunkWrite(ordinal: 1, locator: .text(start: 5, end: 9), text: "blue mug", thumbnail: nil, vector: [0, 1, 0, 0]),
        ]
        let committed = try await writer.commit(fileID: original.id, contentHash: "h1", space: space, chunks: chunks)
        #expect(committed.count == 2)

        let recommitted = try await writer.commit(fileID: original.id, contentHash: "h1", space: space, chunks: [chunks[0]])
        #expect(recommitted.count == 1)

        let duplicate = try await writer.indexedDuplicate(contentHash: "h1", space: space, excluding: copy.id)
        #expect(duplicate == original.id)
        let copied = try await writer.copyIndex(from: original.id, to: copy.id, contentHash: "h1", space: space)
        #expect(copied.count == 1)

        let reader = try IndexReader(url: url)
        let loaded = try await reader.vectors(in: space, after: nil, limit: 10)
        #expect(loaded.count == 2)
        #expect(loaded.allSatisfy { $0.values == [1, 0, 0, 0] })
        #expect(try await reader.counts().indexed[.document] == 2)
    }

    @Test func commitForVanishedFileIsNoOp() async throws {
        let writer = try IndexWriter(url: try makeDatabaseURL())
        let result = try await writer.commit(
            fileID: FileID(999), contentHash: "x", space: space,
            chunks: [ChunkWrite(ordinal: 0, locator: .whole, text: "t", thumbnail: nil, vector: [1, 0, 0, 0])]
        )
        #expect(result.isEmpty)
    }

    @Test func removingSourceCascades() async throws {
        let url = try makeDatabaseURL()
        let writer = try IndexWriter(url: url)
        let source = try await writer.addSource(path: "/s", bookmark: nil)
        _ = try await writer.reconcile(sourceID: source, scanned: [scanned("/s/a.txt")])
        let file = try #require(try await writer.claimPending(limit: 1, kinds: [.document]).first)
        _ = try await writer.commit(fileID: file.id, contentHash: "h", space: space, chunks: [
            ChunkWrite(ordinal: 0, locator: .whole, text: "pricing chart", thumbnail: nil, vector: [1, 0, 0, 0]),
        ])
        let removed = try await writer.removeSource(source)
        #expect(removed == [file.id])

        let reader = try IndexReader(url: url)
        #expect(try await reader.vectors(in: space, after: nil, limit: 10).isEmpty)
        #expect(try await reader.chunkMatches("\"pricing\"", limit: 10).isEmpty)
    }

    @Test func savedSearchesAndSettingsRoundTrip() async throws {
        let url = try makeDatabaseURL()
        let writer = try IndexWriter(url: url)
        _ = try await writer.saveSearch(name: "Receipts", query: "receipt", filter: SearchFilter(kinds: [.image]))
        try await writer.setSetting("k", value: "v")
        try await writer.setSetting("k", value: "w")
        let reader = try IndexReader(url: url)
        let saved = try await reader.savedSearches()
        #expect(saved.first?.filter.kinds == [.image])
        #expect(try await reader.setting("k") == "w")
    }

    @Test func deleteDerivedDataKeepsSources() async throws {
        let url = try makeDatabaseURL()
        let writer = try IndexWriter(url: url)
        let source = try await writer.addSource(path: "/s", bookmark: nil)
        _ = try await writer.reconcile(sourceID: source, scanned: [scanned("/s/a.txt")])
        try await writer.deleteDerivedData()
        #expect(try await writer.counts().totalPending == 0)
        #expect(try await writer.sources().count == 1)
    }
}

@Suite("Keyword search")
struct KeywordSearchTests {
    @Test func findsChunkTextAndNamesWithPrefixes() async throws {
        let url = try makeDatabaseURL()
        let writer = try IndexWriter(url: url)
        let source = try await writer.addSource(path: "/s", bookmark: nil)
        _ = try await writer.reconcile(sourceID: source, scanned: [scanned("/s/Acme Pitch Deck.txt"), scanned("/s/notes.txt")])
        let files = try await writer.claimPending(limit: 2, kinds: [.document])
        let notes = try #require(files.first { $0.name == "notes.txt" })
        _ = try await writer.commit(fileID: notes.id, contentHash: "n", space: space, chunks: [
            ChunkWrite(ordinal: 0, locator: .whole, text: "The flight confirmation for Café Zürich", thumbnail: nil, vector: nil),
        ])

        let reader = try IndexReader(url: url)
        let query = FTSQuery("flight confirm")
        let hits = try await reader.chunkMatches(try #require(query.all), limit: 10)
        #expect(hits.map(\.fileID) == [notes.id])

        let diacritics = try await reader.chunkMatches(try #require(FTSQuery("cafe zurich").all), limit: 10)
        #expect(diacritics.count == 1)

        let names = try await reader.nameMatches(try #require(FTSQuery("acme pi").all), limit: 10)
        #expect(names.count == 1)
        #expect(names.first?.chunkID == nil)
    }
}

@Suite("FTSQuery")
struct FTSQueryTests {
    @Test func dropsStopWordsAndPrefixesLastTerm() {
        let query = FTSQuery("the deck with the pricing ch")
        #expect(query.terms == ["deck", "pricing", "ch"])
        #expect(query.all == "\"deck\" \"pricing\" \"ch\"*")
        #expect(query.any == "\"deck\" OR \"pricing\" OR \"ch\"*")
    }

    @Test func completedWordIsNotPrefixed() {
        #expect(FTSQuery("mug ").all == "\"mug\"")
        #expect(FTSQuery("a").all == "\"a\"")
    }

    @Test func quotesAreNeutralized() {
        #expect(FTSQuery("\"); DROP TABLE files; --").terms == ["drop", "table", "files"])
        #expect(FTSQuery("   ").isEmpty)
    }
}

@Suite("Codecs and thumbnails")
struct CodecTests {
    @Test func halfPrecisionRoundTrip() {
        let values: [Float] = [0.1, -0.5, 0.999, 0]
        let decoded = VectorCodec.decode(VectorCodec.encode(values))
        for (a, b) in zip(values, decoded) { #expect(abs(a - b) < 1e-3) }
    }

    @Test func waveformRoundTripClamps() {
        let decoded = VectorCodec.decodeWaveform(VectorCodec.encodeWaveform([0, 0.5, 1, 2, -1]))
        #expect(decoded.count == 5)
        #expect(decoded[3] == 1)
        #expect(decoded[4] == 0)
    }

    @Test func thumbnailsAreDownscaledAndShared() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thumbs-\(UUID().uuidString)")
        let store = ThumbnailStore(directory: directory, maxPixelSize: 100)
        let context = try #require(CGContext(
            data: nil, width: 800, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        let image = try #require(context.makeImage())
        let path = try store.save(image, contentHash: "abcdef", key: "p0")
        #expect(path == "ab/abcdef-p0.jpg")
        let loaded = try #require(store.image(atRelativePath: path))
        #expect(loaded.width == 100)
        #expect(store.diskUsage() > 0)
    }
}

@Suite("Migrations")
struct MigrationTests {
    @Test func freshDatabaseIsAtCurrentVersion() throws {
        let connection = try SQLiteConnection(url: try makeDatabaseURL())
        try Schema.migrate(connection)
        #expect(try connection.scalarInt("PRAGMA user_version") == Int64(Schema.currentVersion))
        // Re-running is a no-op.
        try Schema.migrate(connection)
    }

    /// Every shipped schema version must upgrade to the current one. Archived fixtures go in
    /// `Tests/GlintStoreTests/Fixtures/schema-vN.sqlite` as versions ship.
    @Test func upgradesFromEveryShippedVersion() throws {
        let fixtures = Bundle.module.urls(forResourcesWithExtension: "sqlite", subdirectory: "Fixtures") ?? []
        #expect(!fixtures.isEmpty)
        for fixture in fixtures {
            let copy = try makeDatabaseURL()
            try FileManager.default.copyItem(at: fixture, to: copy)
            let connection = try SQLiteConnection(url: copy)
            try Schema.migrate(connection)
            #expect(try connection.scalarInt("PRAGMA user_version") == Int64(Schema.currentVersion))
            #expect(try connection.counts().totalPending == 1)
        }
    }
}

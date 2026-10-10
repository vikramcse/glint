import Foundation
import GlintCore
import GlintEmbedding
import GlintSearch
import GlintStore
import Testing
import UniformTypeIdentifiers

@testable import GlintIndexer

/// One chunk per non-empty line of a text file.
private struct LineExtractor: ContentExtractor {
    static let contentTypes: Set<UTType> = [.plainText, .audio]

    func chunks(of file: FileRef) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { continuation in
            do {
                let text = file.kind == .audio ? "voice memo" : try String(contentsOf: file.url, encoding: .utf8)
                if text.contains("CRASH") { throw CocoaError(.fileReadCorruptFile) }
                if text.contains("SLOW") { Thread.sleep(forTimeInterval: 1.5) }
                for (index, line) in text.split(separator: "\n").enumerated() {
                    continuation.yield(
                        Chunk(ordinal: index, locator: .text(start: 0, end: line.count), text: String(line), input: .text(String(line))))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Counts how many inputs were embedded, to prove moves and copies never re-embed.
private final class CountingProvider: EmbeddingProvider, @unchecked Sendable {
    let base = HashingEmbeddingProvider()
    private let lock = NSLock()
    private var embedded = 0

    var descriptor: ModelDescriptor { base.descriptor }
    var count: Int { lock.withLock { embedded } }

    func embed(_ batch: [EmbeddingInput], purpose: EmbeddingPurpose) async throws -> [Embedding] {
        if purpose == .document { lock.withLock { embedded += batch.count } }
        return try await base.embed(batch, purpose: purpose)
    }
}

private final class Harness: Sendable {
    let root: URL
    let library: URL
    let indexer: Indexer
    let engine: SearchEngine
    let provider: CountingProvider
    let writer: IndexWriter

    init(gate: FeatureGateSnapshot = .pro, power: FixedPowerMonitor = FixedPowerMonitor(), root existingRoot: URL? = nil) throws {
        root = existingRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("glint-indexer-\(UUID().uuidString)")
        library = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let paths = AppPaths(root: root.appendingPathComponent("Support"))
        try paths.createDirectories()

        provider = CountingProvider()
        writer = try IndexWriter(url: paths.database)
        let features = FeatureGateBox(gate)
        let vectorIndex = FlatVectorIndex(space: provider.descriptor.space, useGPU: false)
        let priority = PriorityGate(quietPeriod: .milliseconds(1))
        let thumbnails = ThumbnailStore(directory: paths.thumbnails)
        indexer = Indexer(
            writer: writer, extractors: [LineExtractor()], provider: provider, vectorIndex: vectorIndex, gate: priority,
            thumbnails: thumbnails, features: features, power: power,
            options: IndexerOptions(concurrentFiles: 2, watcherLatency: 0.1)
        )
        engine = SearchEngine(
            reader: try IndexReader(url: paths.database), vectorIndex: vectorIndex,
            encoder: GatedQueryEncoder(provider: provider, gate: priority), thumbnails: thumbnails, gate: features
        )
    }

    func write(_ name: String, _ text: String) throws {
        let url = library.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func names(for query: String) async throws -> [String] {
        try await engine.mergedResults(for: SearchQuery(text: query)).items.map(\.file.name)
    }
}

@Suite("Indexer integration", .serialized)
struct IndexerIntegrationTests {
    @Test func indexesCorpusEndToEnd() async throws {
        let harness = try Harness()
        try harness.write("trip.txt", "beach trip to Goa\nhotel receipt")
        try harness.write("work/pitch.txt", "acme pricing chart")
        try harness.write("ignored.bin", "binary")
        try await harness.indexer.addSource(harness.library)
        await harness.indexer.drain()

        let status = await harness.indexer.currentStatus()
        #expect(status.indexed[.document] == 2)
        #expect(status.pending == 0)
        #expect(try await harness.names(for: "hotel receipt").first == "trip.txt")
        #expect(try await harness.names(for: "pricing").first == "pitch.txt")
    }

    @Test func editsRenamesCopiesAndDeletes() async throws {
        let harness = try Harness()
        try harness.write("a.txt", "blue mug on the desk")
        let source = try await harness.indexer.addSource(harness.library)
        await harness.indexer.drain()
        let initialEmbeds = harness.provider.count

        // Rename: no re-embedding, still found under its new name.
        try FileManager.default.moveItem(
            at: harness.library.appendingPathComponent("a.txt"), to: harness.library.appendingPathComponent("mug.txt"))
        _ = try await harness.writer.reconcile(sourceID: source.id, scanned: try FileScanner(exclusions: .default).scan(harness.library))
        await harness.indexer.drain()
        #expect(harness.provider.count == initialEmbeds)
        #expect(try await harness.names(for: "blue mug").first == "mug.txt")

        // Copy: identical content reuses stored vectors.
        try FileManager.default.copyItem(
            at: harness.library.appendingPathComponent("mug.txt"), to: harness.library.appendingPathComponent("copy.txt"))
        _ = try await harness.writer.reconcile(sourceID: source.id, scanned: try FileScanner(exclusions: .default).scan(harness.library))
        await harness.indexer.drain()
        #expect(harness.provider.count == initialEmbeds)
        #expect(Set(try await harness.names(for: "blue mug")) == ["mug.txt", "copy.txt"])

        // Edit: re-embedded and searchable by new content.
        try harness.write("copy.txt", "red kettle")
        _ = try await harness.writer.reconcile(sourceID: source.id, scanned: try FileScanner(exclusions: .default).scan(harness.library))
        await harness.indexer.drain()
        #expect(harness.provider.count > initialEmbeds)
        #expect(try await harness.names(for: "kettle").first == "copy.txt")

        // Delete: gone from keyword and vector results.
        try FileManager.default.removeItem(at: harness.library.appendingPathComponent("copy.txt"))
        let result = try await harness.writer.reconcile(
            sourceID: source.id, scanned: try FileScanner(exclusions: .default).scan(harness.library))
        #expect(result.removed.count == 1)
        for id in result.removed { try await harness.engine.vectorIndex.remove(fileID: id) }
        #expect(!(try await harness.names(for: "kettle")).contains("copy.txt"))
    }

    @Test func watcherPicksUpNewFiles() async throws {
        let harness = try Harness()
        await harness.indexer.start()
        try await harness.indexer.addSource(harness.library)
        try harness.write("later.txt", "flight confirmation")

        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if try await harness.names(for: "flight confirmation").contains("later.txt") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try await harness.names(for: "flight confirmation").contains("later.txt"))
        await harness.indexer.stop()
    }

    @Test func unreadableFilesFailWithoutBlockingTheQueue() async throws {
        let harness = try Harness()
        try harness.write("bad.txt", "CRASH")
        try harness.write("good.txt", "fine")
        try await harness.indexer.addSource(harness.library)
        await harness.indexer.drain()
        let status = await harness.indexer.currentStatus()
        #expect(status.failed == 1)
        #expect(status.indexed[.document] == 1)
    }

    @Test func slowFileDoesNotBlockTheQueue() async throws {
        let harness = try Harness()
        try harness.write("aaa-slow.txt", "SLOW video stand-in")
        for index in 0..<12 { try harness.write("quick-\(index).txt", "quick note \(index)") }
        try await harness.indexer.addSource(harness.library)
        let drain = Task { await harness.indexer.drain() }
        try await Task.sleep(for: .milliseconds(900))
        // With the old batch barrier nothing behind the slow file finished until it did.
        let midway = await harness.indexer.currentStatus()
        #expect(midway.indexed[.document] ?? 0 >= 12)
        await drain.value
        #expect(await harness.indexer.currentStatus().indexed[.document] == 13)
    }

    @Test func relaunchResumesInterruptedWork() async throws {
        let first = try Harness()
        try first.write("a.txt", "alpha")
        try first.write("b.txt", "beta")
        let source = try await first.indexer.addSource(first.library)
        // Simulate a crash after claiming a file but before commit.
        _ = try await first.writer.claimPending(limit: 1, kinds: [.document])
        _ = source

        let relaunched = try Harness(root: first.root)
        await relaunched.indexer.start()
        await relaunched.indexer.drain()
        #expect(await relaunched.indexer.currentStatus().indexed[.document] == 2)
        await relaunched.indexer.stop()
    }

    @Test func freeTierItemLimitPausesWithoutDeleting() async throws {
        let harness = try Harness(gate: FeatureGateSnapshot(enabled: [], itemLimit: 2, sourceLimit: 3))
        for index in 0..<4 { try harness.write("\(index).txt", "note \(index)") }
        try await harness.indexer.addSource(harness.library)
        await harness.indexer.drain()
        let status = await harness.indexer.currentStatus()
        #expect(status.totalIndexed == 2)
        #expect(status.pending == 2)
        #expect(status.phase == .paused(.itemLimitReached))
    }

    @Test func sourcesReportPerFolderProgress() async throws {
        let harness = try Harness(gate: .free)
        try harness.write("a.txt", "alpha")
        try harness.write("b.txt", "beta")
        try harness.write("memo.m4a", "audio")
        try harness.write("bad.txt", "CRASH")
        try await harness.indexer.addSource(harness.library)
        var source = try #require(try await harness.indexer.sources().first)
        #expect(source.itemCount == 4)
        #expect(source.pending == 3)
        #expect(source.locked == 1)
        #expect(!source.isComplete)

        await harness.indexer.drain()
        source = try #require(try await harness.indexer.sources().first)
        #expect(source.indexed == 2)
        #expect(source.failed == 1)
        #expect(source.locked == 1)
        #expect(source.pending == 0)
        #expect(source.isComplete)
    }

    @Test func freeTierLeavesAudioLocked() async throws {
        let harness = try Harness(gate: .free)
        try harness.write("memo.m4a", "not really audio")
        try harness.write("note.txt", "text")
        try await harness.indexer.addSource(harness.library)
        await harness.indexer.drain()
        let status = await harness.indexer.currentStatus()
        #expect(status.locked == 1)
        #expect(status.indexed[.audio] == nil)
    }

    @Test func sourceLimitAndPowerPolicy() async throws {
        let harness = try Harness(
            gate: FeatureGateSnapshot(enabled: [], itemLimit: nil, sourceLimit: 1), power: FixedPowerMonitor(reason: .thermal))
        try FileManager.default.createDirectory(at: harness.root.appendingPathComponent("Other"), withIntermediateDirectories: true)
        try await harness.indexer.addSource(harness.library)
        await #expect(throws: EntitlementError.sourceLimitReached(limit: 1)) {
            try await harness.indexer.addSource(harness.root.appendingPathComponent("Other"))
        }

        await harness.indexer.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while await harness.indexer.currentStatus().phase != .paused(.thermal), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await harness.indexer.currentStatus().phase == .paused(.thermal))
        await harness.indexer.stop()
    }

    @Test func exclusionsApplyBeforeExtraction() async throws {
        let harness = try Harness()
        try harness.write("keep.txt", "keep")
        try harness.write("private/secret.txt", "secret")
        try await harness.indexer.addSource(harness.library)
        try await harness.indexer.setExclusions(ExclusionRules(folders: [harness.library.appendingPathComponent("private").path]))
        await harness.indexer.drain()
        #expect(try await harness.names(for: "secret").isEmpty)
    }

    @Test func reindexSourceReembedsEveryFileAndRetriesFailures() async throws {
        let harness = try Harness()
        try harness.write("a.txt", "alpha")
        try harness.write("bad.txt", "CRASH")
        let source = try await harness.indexer.addSource(harness.library)
        await harness.indexer.drain()
        let initialEmbeds = harness.provider.count

        try await harness.indexer.reindexSource(source.id)
        let queued = try #require(try await harness.indexer.sources().first)
        #expect(queued.pending == 2)
        #expect(queued.failed == 0)
        // Still searchable while it waits to be re-indexed.
        #expect(try await harness.names(for: "alpha").first == "a.txt")

        await harness.indexer.drain()
        #expect(harness.provider.count > initialEmbeds)
        let done = try #require(try await harness.indexer.sources().first)
        #expect(done.indexed == 1)
        #expect(done.failed == 1)
        #expect(try await harness.names(for: "alpha").first == "a.txt")
    }

    @Test func removeSourceDeletesOnlyItsIndex() async throws {
        let harness = try Harness()
        let other = harness.root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "kept note".write(to: other.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
        try harness.write("gone.txt", "removed note")
        let removed = try await harness.indexer.addSource(harness.library)
        try await harness.indexer.addSource(other)
        await harness.indexer.drain()

        try await harness.indexer.removeSource(removed.id)
        #expect(try await harness.indexer.sources().map(\.path) == [FileScanner.canonicalPath(other)])
        #expect(await harness.engine.vectorIndex.count == 1)
        #expect(!(try await harness.names(for: "removed note")).contains("gone.txt"))
        #expect(try await harness.names(for: "kept note").first == "kept.txt")
        #expect(await harness.indexer.currentStatus().totalIndexed == 1)
    }

    @Test func deleteIndexRemovesDerivedDataAndRescans() async throws {
        let harness = try Harness()
        try harness.write("a.txt", "alpha")
        try await harness.indexer.addSource(harness.library)
        await harness.indexer.drain()
        try await harness.indexer.deleteIndex()
        let status = await harness.indexer.currentStatus()
        #expect(status.totalIndexed == 0)
        #expect(status.pending == 1)
        #expect(await harness.engine.vectorIndex.count == 0)
    }
}

@Suite("ContentHasher")
struct ContentHasherTests {
    @Test func identicalContentHashesEqual() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let a = directory.appendingPathComponent("a")
        let b = directory.appendingPathComponent("b")
        let c = directory.appendingPathComponent("c")
        try Data("same".utf8).write(to: a)
        try Data("same".utf8).write(to: b)
        try Data("diff".utf8).write(to: c)
        #expect(try ContentHasher.hash(of: a) == ContentHasher.hash(of: b))
        #expect(try ContentHasher.hash(of: a) != ContentHasher.hash(of: c))
        #expect(try ContentHasher.hash(of: a).hasPrefix("f"))
    }
}

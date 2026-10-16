import Foundation
import GlintCore
import GlintEmbedding
import GlintSearch
import GlintStore
import Testing
import UniformTypeIdentifiers

@testable import GlintIndexer

/// One chunk per line of a text file.
private struct TextLines: ContentExtractor {
    static let contentTypes: Set<UTType> = [.plainText]

    func chunks(of file: FileRef) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { continuation in
            do {
                let text = try String(contentsOf: file.url, encoding: .utf8)
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

/// The real file system, except that the listed folders count as network shares.
private struct NetworkShareProbe: VolumeProbing {
    let shares: Set<String>

    func isReachable(_ path: String) -> Bool { SystemVolumeProbe().isReachable(path) }
    func isNetworkVolume(_ path: String) -> Bool { shares.contains(path) }
}

/// A "share" folder and a local folder. Moving the share away stands in for disconnecting it:
/// like a real mount point, the folder and every file in it disappear at once.
private final class ShareHarness: Sendable {
    let root: URL
    let share: URL
    let local: URL
    let parked: URL
    let indexer: Indexer
    let writer: IndexWriter
    let engine: SearchEngine

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("glint-share-\(UUID().uuidString)")
        share = root.appendingPathComponent("Share", isDirectory: true)
        local = root.appendingPathComponent("Local", isDirectory: true)
        parked = root.appendingPathComponent("Parked", isDirectory: true)
        for folder in [share, local] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let paths = AppPaths(root: root.appendingPathComponent("Support"))
        try paths.createDirectories()

        let provider = HashingEmbeddingProvider()
        writer = try IndexWriter(url: paths.database)
        let vectorIndex = FlatVectorIndex(space: provider.descriptor.space, useGPU: false)
        let gate = PriorityGate(quietPeriod: .milliseconds(1))
        let thumbnails = ThumbnailStore(directory: paths.thumbnails)
        indexer = Indexer(
            writer: writer, extractors: [TextLines()], provider: provider, vectorIndex: vectorIndex, gate: gate,
            thumbnails: thumbnails, power: FixedPowerMonitor(), options: IndexerOptions(concurrentFiles: 2),
            volumes: NetworkShareProbe(shares: [FileScanner.canonicalPath(share)])
        )
        engine = SearchEngine(
            reader: try IndexReader(url: paths.database), vectorIndex: vectorIndex,
            encoder: GatedQueryEncoder(provider: provider, gate: gate), thumbnails: thumbnails
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ name: String, _ text: String, in folder: URL) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func disconnect() throws { try FileManager.default.moveItem(at: share, to: parked) }
    func reconnect() throws { try FileManager.default.moveItem(at: parked, to: share) }

    func counts(_ id: SourceID) async throws -> IndexCounts {
        try await writer.sourceCounts()[id] ?? IndexCounts()
    }

    func names(for query: String) async throws -> [String] {
        try await engine.mergedResults(for: SearchQuery(text: query)).items.map(\.file.name)
    }
}

@Suite("Network shares", .serialized)
struct NetworkShareTests {
    @Test func reportsShareAndDisconnection() async throws {
        let harness = try ShareHarness()
        let added = try await harness.indexer.addSource(harness.share)
        #expect(added.isNetworkVolume)
        #expect(added.isAccessible)

        try harness.disconnect()
        await harness.indexer.refreshVolumes()
        let source = try #require(try await harness.indexer.sources().first)
        #expect(source.isNetworkVolume, "a disconnected share still shows as a share")
        #expect(!source.isAccessible)
        #expect(await harness.indexer.currentStatus().inaccessibleSources == 1)
    }

    @Test func pendingFilesWaitForADisconnectedShare() async throws {
        let harness = try ShareHarness()
        for index in 0..<6 { try harness.write("note\(index).txt", "harbour sketch \(index)", in: harness.share) }
        let source = try await harness.indexer.addSource(harness.share)
        #expect(try await harness.counts(source.id).totalPending == 6)

        // The share drops before indexing starts: nothing is deleted, failed or retried away.
        try harness.disconnect()
        await harness.indexer.drain()
        let offline = try await harness.counts(source.id)
        #expect(offline.totalPending == 6)
        #expect(offline.failed == 0)
        #expect(await harness.indexer.offlineSources == [source.id])

        try harness.reconnect()
        await harness.indexer.refreshVolumes()
        #expect(await harness.indexer.offlineSources.isEmpty)
        await harness.indexer.drain()
        #expect(try await harness.counts(source.id).totalIndexed == 6)
        #expect(try await harness.names(for: "harbour sketch").count == 6)
    }

    @Test func watcherEventsFromADisconnectedShareKeepItsFiles() async throws {
        let harness = try ShareHarness()
        try harness.write("plan.txt", "lighthouse renovation plan", in: harness.share)
        let source = try await harness.indexer.addSource(harness.share)
        await harness.indexer.drain()

        try harness.disconnect()
        let file = FileScanner.canonicalPath(harness.share.appendingPathComponent("plan.txt"))
        await harness.indexer.handle(
            FileSystemChange(paths: [file, FileScanner.canonicalPath(harness.share)], rescanRoots: []))
        #expect(try await harness.counts(source.id).totalIndexed == 1)
        #expect(try await harness.names(for: "lighthouse").first == "plan.txt")
    }

    @Test func refreshRescansSharesButNotLocalFolders() async throws {
        let harness = try ShareHarness()
        let share = try await harness.indexer.addSource(harness.share)
        let local = try await harness.indexer.addSource(harness.local)

        // Written "from another Mac": no watcher is running, so only a rescan can see these.
        try harness.write("remote.txt", "quarterly budget", in: harness.share)
        try harness.write("here.txt", "grocery list", in: harness.local)
        await harness.indexer.refreshVolumes()

        #expect(try await harness.counts(share.id).totalPending == 1)
        #expect(try await harness.counts(local.id).totalPending == 0, "local folders rely on FSEvents")
    }
}

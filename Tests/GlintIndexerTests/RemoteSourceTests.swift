import Foundation
import GlintCore
import GlintEmbedding
import GlintSearch
import GlintStore
import Testing
import UniformTypeIdentifiers

@testable import GlintIndexer

/// One chunk per line of a text file.
private struct Lines: ContentExtractor {
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

/// A remote service in memory: files can be added, edited and deleted, and the service can go
/// unreachable. Also stands in for the Keychain.
private final class FakeRemote: RemoteStorage, RemoteStorageResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: (text: String, modified: Date)] = [:]
    private var reachable = true
    private var secrets: [String: String] = [:]
    private var downloadCount = 0

    func put(_ key: String, _ text: String, modified: TimeInterval = 1_000) {
        lock.withLock { files[key] = (text, Date(timeIntervalSince1970: modified)) }
    }

    func delete(_ key: String) { lock.withLock { files[key] = nil } }
    func setReachable(_ value: Bool) { lock.withLock { reachable = value } }
    var savedSecrets: [String: String] { lock.withLock { secrets } }
    var downloads: Int { lock.withLock { downloadCount } }

    private func checkReachable() throws {
        if !lock.withLock({ reachable }) { throw RemoteStorageError.unreachable("offline") }
    }

    // RemoteStorage

    func connect() async throws -> RemoteSourceConfig {
        try checkReachable()
        return RemoteSourceConfig(service: .s3)
    }

    func list() async throws -> [RemoteObject] {
        try checkReachable()
        return lock.withLock {
            files.map { RemoteObject(key: $0.key, size: Int64($0.value.text.utf8.count), modified: $0.value.modified) }
        }
    }

    func download(key: String, to directory: URL) async throws -> URL {
        try checkReachable()
        guard let file = lock.withLock({ files[key] }) else { throw RemoteStorageError.notFound(key) }
        lock.withLock { downloadCount += 1 }
        let url = directory.appendingPathComponent(key.split(separator: "/").last.map(String.init) ?? key)
        try file.text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // RemoteStorageResolving

    func storage(for config: RemoteSourceConfig, secret: String?) throws -> any RemoteStorage {
        guard secret != nil || lock.withLock({ secrets[config.credentialID] }) != nil else {
            throw RemoteStorageError.unauthorized("no secret")
        }
        return Connected(remote: self, config: config)
    }

    func saveSecret(_ secret: String, credentialID: String) throws { lock.withLock { secrets[credentialID] = secret } }
    func deleteSecret(credentialID: String) { lock.withLock { secrets[credentialID] = nil } }

    /// Returns the caller's config from `connect`, as real storage does.
    struct Connected: RemoteStorage {
        let remote: FakeRemote
        let config: RemoteSourceConfig

        func connect() async throws -> RemoteSourceConfig {
            _ = try await remote.connect()
            return config
        }
        func list() async throws -> [RemoteObject] { try await remote.list() }
        func download(key: String, to directory: URL) async throws -> URL { try await remote.download(key: key, to: directory) }
    }
}

private final class RemoteHarness: Sendable {
    let root: URL
    let remote = FakeRemote()
    let indexer: Indexer
    let writer: IndexWriter
    let engine: SearchEngine
    let config = RemoteSourceConfig(
        service: .s3, endpoint: "https://s3.example.com", region: "us-east-1", bucket: "team", folder: "notes", accessKeyID: "AKID",
        credentialID: "cred-1")

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("glint-remote-\(UUID().uuidString)")
        let paths = AppPaths(root: root)
        try paths.createDirectories()
        let provider = HashingEmbeddingProvider()
        writer = try IndexWriter(url: paths.database)
        let vectorIndex = FlatVectorIndex(space: provider.descriptor.space, useGPU: false)
        let gate = PriorityGate(quietPeriod: .milliseconds(1))
        let thumbnails = ThumbnailStore(directory: paths.thumbnails)
        indexer = Indexer(
            writer: writer, extractors: [Lines()], provider: provider, vectorIndex: vectorIndex, gate: gate, thumbnails: thumbnails,
            power: FixedPowerMonitor(), options: IndexerOptions(concurrentFiles: 2), remotes: remote)
        engine = SearchEngine(
            reader: try IndexReader(url: paths.database), vectorIndex: vectorIndex,
            encoder: GatedQueryEncoder(provider: provider, gate: gate), thumbnails: thumbnails)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func paths(for query: String) async throws -> [String] {
        try await engine.mergedResults(for: SearchQuery(text: query)).items.map(\.file.path)
    }

    func counts(_ id: SourceID) async throws -> IndexCounts {
        try await writer.sourceCounts()[id] ?? IndexCounts()
    }
}

@Suite("Remote sources", .serialized)
struct RemoteSourceTests {
    @Test func addsIndexesAndSearchesARemoteFolder() async throws {
        let harness = try RemoteHarness()
        harness.remote.put("standup.txt", "migrate the billing service")
        harness.remote.put("2024/retro.txt", "celebrate the launch")
        harness.remote.put("diagram.bin", "not indexable")

        #expect(try await harness.indexer.checkRemoteSource(harness.config, secret: "s3cret") == 2)
        let source = try await harness.indexer.addRemoteSource(harness.config, secret: "s3cret")
        #expect(source.remote == harness.config)
        #expect(source.displayName == "notes")
        #expect(source.path == "s3://s3.example.com/team/notes")
        #expect(harness.remote.savedSecrets == ["cred-1": "s3cret"])

        await harness.indexer.drain()
        #expect(try await harness.counts(source.id).totalIndexed == 2)
        #expect(try await harness.paths(for: "billing service").first == "s3://s3.example.com/team/notes/standup.txt")
        #expect(try await harness.paths(for: "launch").first == "s3://s3.example.com/team/notes/2024/retro.txt")

        let copy = try await harness.indexer.downloadRemoteFile(
            path: "s3://s3.example.com/team/notes/2024/retro.txt", to: FileManager.default.temporaryDirectory)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "celebrate the launch")
    }

    @Test func refreshPicksUpRemoteEditsAndDeletions() async throws {
        let harness = try RemoteHarness()
        harness.remote.put("a.txt", "orange kite")
        harness.remote.put("b.txt", "purple umbrella")
        let source = try await harness.indexer.addRemoteSource(harness.config, secret: "s3cret")
        await harness.indexer.drain()
        let downloads = harness.remote.downloads

        harness.remote.put("a.txt", "green lantern", modified: 2_000)
        harness.remote.delete("b.txt")
        harness.remote.put("c.txt", "silver teapot")
        await harness.indexer.refreshSources()
        await harness.indexer.drain()

        #expect(try await harness.counts(source.id).totalIndexed == 2)
        #expect(try await harness.paths(for: "green lantern").first?.hasSuffix("/a.txt") == true)
        #expect(try await harness.paths(for: "purple umbrella").isEmpty)
        #expect(try await harness.paths(for: "silver teapot").first?.hasSuffix("/c.txt") == true)
        #expect(harness.remote.downloads == downloads + 2, "unchanged files are not downloaded again")
    }

    @Test func anUnreachableServiceKeepsItsFilesAndResumes() async throws {
        let harness = try RemoteHarness()
        harness.remote.put("kept.txt", "quarterly roadmap")
        let source = try await harness.indexer.addRemoteSource(harness.config, secret: "s3cret")
        await harness.indexer.drain()

        // Listed, then the service drops before the new file downloads.
        harness.remote.put("new.txt", "hiring plan")
        await harness.indexer.refreshSources()
        harness.remote.setReachable(false)
        await harness.indexer.drain()
        var counts = try await harness.counts(source.id)
        #expect(counts.totalPending == 1)
        #expect(counts.failed == 0)
        #expect(await harness.indexer.offlineSources == [source.id])

        // Still unreachable at the next poll: nothing is deleted, and it shows as not connected.
        await harness.indexer.refreshSources()
        #expect(try await harness.paths(for: "quarterly roadmap").count == 1)
        let info = try #require(try await harness.indexer.sources().first)
        #expect(!info.isAccessible)

        harness.remote.setReachable(true)
        await harness.indexer.refreshSources()
        await harness.indexer.drain()
        counts = try await harness.counts(source.id)
        #expect(counts.totalIndexed == 2)
        #expect(try await harness.paths(for: "hiring plan").count == 1)
    }

    @Test func aFileDeletedBeforeItsDownloadIsRemoved() async throws {
        let harness = try RemoteHarness()
        harness.remote.put("brief.txt", "temporary brief")
        let source = try await harness.indexer.addRemoteSource(harness.config, secret: "s3cret")
        harness.remote.delete("brief.txt")
        await harness.indexer.drain()
        #expect(try await harness.counts(source.id).totalPending == 0)
        #expect(try await harness.writer.sourceCounts()[source.id] == nil)
        #expect(await harness.indexer.offlineSources.isEmpty)
    }

    @Test func removingTheSourceDeletesItsSecret() async throws {
        let harness = try RemoteHarness()
        harness.remote.put("a.txt", "note")
        let source = try await harness.indexer.addRemoteSource(harness.config, secret: "s3cret")
        try await harness.indexer.removeSource(source.id)
        #expect(harness.remote.savedSecrets.isEmpty)
        #expect(try await harness.indexer.sources().isEmpty)
    }

    @Test func aFailedConnectionAddsNothing() async throws {
        let harness = try RemoteHarness()
        harness.remote.setReachable(false)
        await #expect(throws: RemoteStorageError.unreachable("offline")) {
            try await harness.indexer.addRemoteSource(harness.config, secret: "s3cret")
        }
        #expect(try await harness.indexer.sources().isEmpty)
        #expect(harness.remote.savedSecrets.isEmpty)
    }
}

@Suite("Remote paths")
struct RemotePathTests {
    @Test func rootPathsAndKeys() {
        let s3 = RemoteSourceConfig(service: .s3, endpoint: "https://acct.r2.cloudflarestorage.com", bucket: "media", folder: "/")
        #expect(s3.rootPath == "s3://acct.r2.cloudflarestorage.com/media")
        #expect(RemotePath.key(of: s3.rootPath + "/a/b.jpg", inRoot: s3.rootPath) == "a/b.jpg")
        #expect(RemotePath.key(of: s3.rootPath + "x/b.jpg", inRoot: s3.rootPath) == nil)
        #expect(RemotePath.service(of: s3.rootPath + "/a.jpg") == .s3)
        #expect(RemotePath.service(of: "ftp://host/a.jpg") == nil, "only S3 is a remote service")
        #expect(RemotePath.service(of: "/Users/ana/a.jpg") == nil)
        #expect(RemotePath.folder(of: s3.rootPath + "/Trips/a.jpg") == "media/Trips")
        #expect(s3.locationDescription == "S3 Bucket · media · acct.r2.cloudflarestorage.com")
    }
}

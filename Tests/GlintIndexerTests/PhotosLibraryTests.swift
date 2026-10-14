import Foundation
import GlintCore
import GlintEmbedding
import GlintSearch
import GlintStore
import Testing
import UniformTypeIdentifiers

@testable import GlintIndexer

/// A Photos library backed by text files, so tests exercise the real pipeline without PhotoKit.
private final class FakePhotoLibrary: PhotoLibraryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var assets: [String: (info: PhotoAssetInfo, text: String, isLocal: Bool)] = [:]
    private var continuation: AsyncStream<Void>.Continuation?
    var status: PhotoLibraryAuthorization
    let grantOnRequest: Bool

    init(status: PhotoLibraryAuthorization = .authorized, grantOnRequest: Bool = true) {
        self.status = status
        self.grantOnRequest = grantOnRequest
    }

    func add(_ identifier: String, filename: String, text: String, isLocal: Bool = true) {
        let info = PhotoAssetInfo(
            identifier: identifier, filename: filename, kind: .image, contentType: .plainText,
            size: Int64(text.utf8.count), modified: Date(timeIntervalSince1970: 1_000))
        lock.withLock { assets[identifier] = (info, text, isLocal) }
    }

    func notifyChange() { lock.withLock { continuation }?.yield() }

    func authorizationStatus() -> PhotoLibraryAuthorization { lock.withLock { status } }

    func requestAuthorization() async -> PhotoLibraryAuthorization {
        lock.withLock {
            status = grantOnRequest ? .authorized : .denied
            return status
        }
    }

    func localAssets() async throws -> [PhotoAssetInfo] {
        lock.withLock { assets.values.map(\.info) }
    }

    func exportOriginal(assetIdentifier: String, to directory: URL) async throws -> URL {
        guard let asset = lock.withLock({ assets[assetIdentifier] }), asset.isLocal else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let url = directory.appendingPathComponent(asset.info.filename)
        try asset.text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        lock.withLock { self.continuation = continuation }
        return stream
    }
}

private struct TextAsImageExtractor: ContentExtractor {
    static let contentTypes: Set<UTType> = [.plainText]

    func chunks(of file: FileRef) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { continuation in
            do {
                let text = try String(contentsOf: file.url, encoding: .utf8)
                continuation.yield(Chunk(ordinal: 0, locator: .whole, text: text, input: .text(text)))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

private struct PhotosHarness {
    let indexer: Indexer
    let engine: SearchEngine
    let library: FakePhotoLibrary

    init(library: FakePhotoLibrary = FakePhotoLibrary()) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glint-photos-\(UUID().uuidString)")
        let paths = AppPaths(root: root)
        try paths.createDirectories()
        let provider = HashingEmbeddingProvider()
        let writer = try IndexWriter(url: paths.database)
        let vectorIndex = FlatVectorIndex(space: provider.descriptor.space, useGPU: false)
        let priority = PriorityGate(quietPeriod: .milliseconds(1))
        let thumbnails = ThumbnailStore(directory: paths.thumbnails)
        self.library = library
        indexer = Indexer(
            writer: writer, extractors: [TextAsImageExtractor()], provider: provider, vectorIndex: vectorIndex,
            gate: priority, thumbnails: thumbnails, power: FixedPowerMonitor(),
            options: IndexerOptions(concurrentFiles: 2), photos: library)
        engine = SearchEngine(
            reader: try IndexReader(url: paths.database), vectorIndex: vectorIndex,
            encoder: GatedQueryEncoder(provider: provider, gate: priority), thumbnails: thumbnails)
    }

    func names(_ query: String) async throws -> [String] {
        try await engine.mergedResults(for: SearchQuery(text: query)).items.map(\.file.name)
    }
}

@Suite("Photos library source", .serialized)
struct PhotosLibraryTests {
    @Test func indexesLocalAssetsAsOneSource() async throws {
        let harness = try PhotosHarness()
        harness.library.add("A1/L0/001", filename: "IMG_0001.HEIC", text: "receipt from the hotel in Goa")
        harness.library.add("B2/L0/001", filename: "IMG_0002.HEIC", text: "birthday cake")
        let source = try await harness.indexer.addSource(PhotosLibraryPath.libraryURL)
        #expect(source.isPhotosLibrary)
        #expect(source.isAccessible)
        #expect(source.displayName == "Photos Library")
        await harness.indexer.drain()

        let status = await harness.indexer.currentStatus()
        #expect(status.indexed[.image] == 2)
        let results = try await harness.engine.mergedResults(for: SearchQuery(text: "hotel receipt")).items
        let first = try #require(results.first)
        #expect(first.file.name == "IMG_0001.HEIC")
        #expect(PhotosLibraryPath.assetIdentifier(fromPath: first.file.path) == "A1/L0/001")
    }

    @Test func deniedAccessAddsNothing() async throws {
        let harness = try PhotosHarness(library: FakePhotoLibrary(status: .notDetermined, grantOnRequest: false))
        await #expect(throws: IndexerError.sourceUnreadable) {
            try await harness.indexer.addSource(PhotosLibraryPath.libraryURL)
        }
        #expect(try await harness.indexer.sources().isEmpty)
    }

    @Test func iCloudOnlyOriginalsFailWithoutDownloading() async throws {
        let harness = try PhotosHarness()
        harness.library.add("C3/L0/001", filename: "IMG_0003.HEIC", text: "only in iCloud", isLocal: false)
        try await harness.indexer.addSource(PhotosLibraryPath.libraryURL)
        await harness.indexer.drain()
        let status = await harness.indexer.currentStatus()
        #expect(status.failed == 1)
        #expect(status.totalIndexed == 0)
    }

    @Test func libraryChangesAreIndexed() async throws {
        let harness = try PhotosHarness()
        await harness.indexer.start()
        try await harness.indexer.addSource(PhotosLibraryPath.libraryURL)
        harness.library.add("D4/L0/001", filename: "IMG_0004.HEIC", text: "sunset over the harbour")
        harness.library.notifyChange()
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, !(try await harness.names("sunset harbour")).contains("IMG_0004.HEIC") {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await harness.names("sunset harbour").contains("IMG_0004.HEIC"))
        await harness.indexer.stop()
    }

    @Test func deniedLaterKeepsRowsAndReportsUnreadable() async throws {
        let harness = try PhotosHarness()
        harness.library.add("E5/L0/001", filename: "IMG_0005.HEIC", text: "mountain")
        try await harness.indexer.addSource(PhotosLibraryPath.libraryURL)
        await harness.indexer.drain()
        harness.library.status = .denied
        let source = try #require(try await harness.indexer.sources().first)
        #expect(!source.isAccessible)
        #expect(source.indexed == 1)
    }
}

@Suite("PhotosLibraryPath")
struct PhotosLibraryPathTests {
    @Test func roundTripsIdentifiersWithSlashes() {
        let path = PhotosLibraryPath.path(forAsset: "9F1C-22/L0/001", filename: "IMG_1.HEIC")
        #expect(path == "photos://asset/9F1C-22/L0/001/IMG_1.HEIC")
        #expect(PhotosLibraryPath.assetIdentifier(fromPath: path) == "9F1C-22/L0/001")
        #expect(PhotosLibraryPath.filename(fromPath: path) == "IMG_1.HEIC")
        #expect(PhotosLibraryPath.isAsset(path))
        #expect(!PhotosLibraryPath.isAsset("/Users/a/Pictures/x.jpg"))
        #expect(PhotosLibraryPath.assetIdentifier(fromPath: "/Users/a/x.jpg") == nil)
    }

    @Test func sanitizesFilenames() {
        #expect(PhotosLibraryPath.path(forAsset: "X", filename: "a/b.jpg") == "photos://asset/X/a-b.jpg")
        #expect(PhotosLibraryPath.path(forAsset: "X", filename: "") == "photos://asset/X/Photo")
        #expect(PhotosLibraryPath.libraryURL.scheme == "photos")
    }
}

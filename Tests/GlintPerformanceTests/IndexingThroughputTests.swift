import Foundation
import GlintCore
import GlintEmbedding
import GlintExtractors
import GlintIndexer
import GlintSearch
import GlintStore
import GlintTestSupport
import Testing

/// Indexing throughput floors per media kind, measured with a near-free embedding provider so
/// they guard Glint's own pipeline (hashing, decoding, OCR, batching, commits), not a model.
/// Floors are set for the M1 8 GB reference Mac at about a quarter of an M5's rate; a change
/// that drops below one does not merge. Model throughput is tracked with `glint-eval bench`.
///
/// Run with `GLINT_PERF=1 swift test -c release --filter IndexingThroughputTests`.
@Suite("Indexing throughput", .serialized, .enabled(if: ProcessInfo.processInfo.environment["GLINT_PERF"] != nil))
struct IndexingThroughputTests {
    /// Minimum items per minute.
    enum Floor {
        static let screenshots = 400.0
        static let photos = 600.0
        static let pdfs = 800.0
        static let docs = 5_000.0
        static let audio = 400.0
        static let videos = 40.0
    }

    static func itemsPerMinute(_ folder: URL) async throws -> (rate: Double, indexed: Int, failed: Int) {
        let work = try TemporaryDirectory(prefix: "glint-throughput")
        let paths = AppPaths(root: work.url)
        try paths.createDirectories()
        let provider = PipelineEmbeddingProvider()
        let indexer = Indexer(
            writer: try IndexWriter(url: paths.database), extractors: ExtractorRegistry.standard(transcriber: nil).extractors,
            provider: provider, vectorIndex: FlatVectorIndex(space: provider.descriptor.space), gate: PriorityGate(),
            thumbnails: ThumbnailStore(directory: paths.thumbnails), power: FixedPowerMonitor()
        )
        let stopwatch = Stopwatch()
        try await indexer.addSource(folder)
        await indexer.drain()
        let seconds = stopwatch.milliseconds / 1_000
        let status = await indexer.currentStatus()
        return (Double(status.totalIndexed) / seconds * 60, status.totalIndexed, status.failed)
    }

    static func check(_ name: String, folder: URL, count: Int, floor: Double) async throws {
        let result = try await itemsPerMinute(folder)
        print("\(name): \(Int(result.rate)) items/min (floor \(Int(floor)))")
        #expect(result.indexed == count)
        #expect(result.failed == 0)
        #expect(result.rate >= floor, "\(name) indexed at \(Int(result.rate)) items/min, below the \(Int(floor)) floor")
    }

    @Test func screenshotsAndPhotos() async throws {
        let corpus = try TemporaryDirectory(prefix: "glint-throughput-images")
        let screenshots = try corpus.subdirectory("screenshots")
        for index in 0..<40 {
            try Fixtures.writeTextImage(
                "Invoice \(index) deadline Friday for the Acme pitch deck", named: "shot-\(index).png", in: screenshots,
                size: CGSize(width: 2_880, height: 1_800))
        }
        try await Self.check("screenshots", folder: screenshots, count: 40, floor: Floor.screenshots)

        let photos = try corpus.subdirectory("photos")
        for index in 0..<40 {
            try Fixtures.writeGradientImage(named: "photo-\(index).png", in: photos, size: CGSize(width: 4_032, height: 3_024))
        }
        try await Self.check("photos", folder: photos, count: 40, floor: Floor.photos)
    }

    @Test func documentsAndPDFs() async throws {
        let corpus = try TemporaryDirectory(prefix: "glint-throughput-docs")
        let docs = try corpus.subdirectory("docs")
        let paragraph = String(repeating: "Quarterly planning notes for the Acme account and the Friday deadline. ", count: 40)
        for index in 0..<200 { _ = try Fixtures.writeText("# Note \(index)\n\n\(paragraph)", named: "note-\(index).md", in: docs) }
        try await Self.check("docs", folder: docs, count: 200, floor: Floor.docs)

        let pdfs = try corpus.subdirectory("pdfs")
        for index in 0..<20 {
            _ = try Fixtures.writePDF(
                pages: (0..<10).map { "Report \(index) page \($0). \(paragraph)" }, named: "report-\(index).pdf", in: pdfs)
        }
        try await Self.check("pdfs", folder: pdfs, count: 20, floor: Floor.pdfs)
    }

    @Test func audioAndVideo() async throws {
        let corpus = try TemporaryDirectory(prefix: "glint-throughput-media")
        let audio = try corpus.subdirectory("audio")
        for index in 0..<6 {
            try Fixtures.writeToneWAV(duration: 90, frequency: 220 + Double(index * 50), named: "memo-\(index).wav", in: audio)
        }
        try await Self.check("audio", folder: audio, count: 6, floor: Floor.audio)

        let videos = try corpus.subdirectory("videos")
        for index in 0..<3 {
            try await Fixtures.writeVideo(
                duration: 30, named: "clip-\(index).mp4", in: videos, size: CGSize(width: 1_920, height: 1_080), framesPerSecond: 30)
        }
        try await Self.check("videos", folder: videos, count: 3, floor: Floor.videos)
    }
}

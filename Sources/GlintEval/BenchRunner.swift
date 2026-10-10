import Foundation
import GlintCore
import GlintEmbedding
import GlintExtractors
import GlintIndexer
import GlintSearch
import GlintStore

/// Result of indexing one folder from scratch.
struct BenchRun: Codable, Sendable {
    struct Stage: Codable, Sendable {
        var files: Int
        var bytes: Int64
        var chunks: Int
        var vectors: Int
        /// Seconds per stage, summed across concurrent workers.
        var stageSeconds: [String: Double]
    }

    var name: String
    var files: Int
    var failed: Int
    var wallSeconds: Double
    var itemsPerMinute: Double
    /// Files whose extracted text contains "deadline" (in every screenshot, PDF and doc), a
    /// guard that speedups never come from skipping OCR or text extraction.
    var filesWithKeyword: Int
    var perKind: [String: Stage]
}

struct BenchReport: Codable, Sendable {
    var model: String
    var date: Date
    var machine: String
    var runs: [BenchRun]
}

/// Indexes each kind's folder separately, then everything together, each into a fresh index.
struct BenchRunner {
    let corpus: URL
    let provider: any EmbeddingProvider
    var options = IndexerOptions()

    func run(kinds: [String]) async throws -> [BenchRun] {
        var runs: [BenchRun] = []
        for kind in kinds {
            runs.append(try await index(name: kind, folder: corpus.appendingPathComponent(kind, isDirectory: true)))
            print(Self.line(runs[runs.count - 1]))
        }
        runs.append(try await index(name: "all", folder: corpus))
        print(Self.line(runs[runs.count - 1]))
        return runs
    }

    func index(name: String, folder: URL) async throws -> BenchRun {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("glint-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let paths = AppPaths(root: work)
        try paths.createDirectories()
        let writer = try IndexWriter(url: paths.database)
        let stats = IndexingStats()
        let indexer = Indexer(
            writer: writer, extractors: ExtractorRegistry.standard(transcriber: nil).extractors, provider: provider,
            vectorIndex: FlatVectorIndex(space: provider.descriptor.space), gate: PriorityGate(),
            thumbnails: ThumbnailStore(directory: paths.thumbnails), features: FeatureGateBox(.pro), power: FixedPowerMonitor(),
            options: options, stats: stats
        )
        let stopwatch = Stopwatch()
        try await indexer.addSource(folder)
        await indexer.drain()
        let wall = stopwatch.milliseconds / 1_000
        let status = await indexer.currentStatus()
        let kinds = await stats.kinds
        var perKind: [String: BenchRun.Stage] = [:]
        for (kind, value) in kinds {
            perKind[kind.rawValue] = BenchRun.Stage(
                files: value.files, bytes: value.bytes, chunks: value.chunks, vectors: value.vectors,
                stageSeconds: Dictionary(uniqueKeysWithValues: value.stageSeconds.map { ($0.key.rawValue, $0.value) }))
        }
        let files = status.totalIndexed
        let hits = try await IndexReader(url: paths.database).chunkMatches("\"deadline\"", limit: 100_000)
        return BenchRun(
            name: name, files: files, failed: status.failed, wallSeconds: wall,
            itemsPerMinute: wall > 0 ? Double(files) / wall * 60 : 0, filesWithKeyword: Set(hits.map(\.fileID)).count,
            perKind: perKind)
    }

    static func line(_ run: BenchRun) -> String {
        var text = run.name.padding(toLength: 12, withPad: " ", startingAt: 0)
            + String(
                format: "%5d files  %7.1f s  %8.0f items/min  text✓ %d", run.files, run.wallSeconds, run.itemsPerMinute,
                run.filesWithKeyword)
        if run.failed > 0 { text += "  (\(run.failed) failed)" }
        for (kind, stage) in run.perKind.sorted(by: { $0.key < $1.key }) {
            let stages = IndexingStage.allCases.map { String(format: "%@ %.1f", $0.rawValue, stage.stageSeconds[$0.rawValue] ?? 0) }
            text += "\n    \(kind.padding(toLength: 9, withPad: " ", startingAt: 0)) " + stages.joined(separator: "  ")
        }
        return text
    }
}

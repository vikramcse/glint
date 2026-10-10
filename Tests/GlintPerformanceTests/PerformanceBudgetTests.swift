import Foundation
import GlintCore
import GlintEmbedding
import GlintSearch
import GlintStore
import GlintTestSupport
import Testing

/// Performance budgets from the PRD, measured at the specified scale (100k chunks, 512 d).
/// Budgets are set for the M1 8 GB floor; a change that breaks one does not merge.
///
/// Run with `GLINT_PERF=1 swift test -c release --filter GlintPerformanceTests`.
@Suite("Performance budgets", .serialized, .enabled(if: ProcessInfo.processInfo.environment["GLINT_PERF"] != nil))
struct PerformanceBudgetTests {
    static let chunkCount = 100_000
    static let dimension = 512

    /// p95 milliseconds per budgeted interaction.
    enum Budget {
        static let keywordSearch = 30.0
        static let queryEmbedding = 30.0
        static let vectorScan = 20.0
        static let mergedResults = 150.0
    }

    static func measure(_ iterations: Int, _ body: () async throws -> Void) async rethrows -> (p50: Double, p95: Double) {
        var samples: [Double] = []
        for _ in 0..<iterations {
            let stopwatch = Stopwatch()
            try await body()
            samples.append(stopwatch.milliseconds)
        }
        return (RetrievalMetrics.percentile(samples, 50), RetrievalMetrics.percentile(samples, 95))
    }

    static func randomVectors(_ count: Int, space: VectorSpace) -> [StoredVector] {
        var generator = SystemRandomNumberGenerator()
        let attributes = FileAttributes(kind: .image, modified: Date(), path: "/perf/file")
        return (0..<count).map { row in
            let values = (0..<space.dimension).map { _ in Float.random(in: -1...1, using: &generator) }
            return StoredVector(
                chunkID: ChunkID(Int64(row + 1)), fileID: FileID(Int64(row / 4 + 1)),
                values: Embedding(normalizing: values, space: space).values, attributes: attributes
            )
        }
    }

    @Test func vectorScanAt100kChunks() async throws {
        let space = VectorSpace(modelID: "perf", dimension: Self.dimension)
        let index = FlatVectorIndex(space: space, initialCapacity: Self.chunkCount)
        try await index.upsert(Self.randomVectors(Self.chunkCount, space: space))
        let query = Embedding(normalizing: (0..<Self.dimension).map { Float($0 % 7) - 3 }, space: space)
        _ = try await index.search(query, limit: 240, filter: .none)  // warm the pipeline

        let timing = try await Self.measure(50) { _ = try await index.search(query, limit: 240, filter: .none) }
        print("Vector scan 100k×512: p50 \(timing.p50) ms, p95 \(timing.p95) ms")
        #expect(timing.p95 <= Budget.vectorScan)
    }

    @Test func queryEmbeddingWarm() async throws {
        let encoder = GatedQueryEncoder(provider: try AppleOnDeviceEmbeddingProvider(), gate: PriorityGate())
        _ = try await encoder.encode(query: "warm up")
        let queries = ["crowd cheering at night", "pricing chart", "flight confirmation", "blue mug on a desk"]
        var index = 0
        let timing = try await Self.measure(40) {
            _ = try await encoder.encode(query: queries[index % queries.count])
            index += 1
        }
        print("Query embedding (warm): p50 \(timing.p50) ms, p95 \(timing.p95) ms")
        #expect(timing.p95 <= Budget.queryEmbedding)
    }

    @Test func keystrokeAndMergedResultsAt100kChunks() async throws {
        let directory = try TemporaryDirectory(prefix: "glint-perf")
        let url = directory.url.appendingPathComponent("index.sqlite")
        let space = VectorSpace(modelID: "perf", dimension: Self.dimension)
        let writer = try IndexWriter(url: url)
        try await Self.populate(writer, space: space)

        let index = FlatVectorIndex(space: space, initialCapacity: Self.chunkCount)
        let engine = SearchEngine(
            reader: try IndexReader(url: url), vectorIndex: index,
            encoder: GatedQueryEncoder(provider: PerfEncoder(space: space), gate: PriorityGate()),
            thumbnails: ThumbnailStore(directory: directory.url), gate: FeatureGateBox(.pro)
        )
        let loaded = try await engine.loadVectors()
        #expect(loaded == Self.chunkCount)

        // Each keystroke of a typed query, as the panel issues them.
        let typed = "quarterly revenue chart for acme"
        let prefixes = (2...typed.count).map { String(typed.prefix($0)) }
        _ = try await engine.keywordResults(for: SearchQuery(text: "warm"))
        var keyword: [Double] = []
        var merged: [Double] = []
        for _ in 0..<3 {
            for prefix in prefixes {
                var stopwatch = Stopwatch()
                _ = try await engine.keywordResults(for: SearchQuery(text: prefix + " "))
                keyword.append(stopwatch.milliseconds)
                stopwatch = Stopwatch()
                _ = try await engine.mergedResults(for: SearchQuery(text: prefix))
                merged.append(stopwatch.milliseconds)
            }
        }
        let keywordP95 = RetrievalMetrics.percentile(keyword, 95)
        let mergedP95 = RetrievalMetrics.percentile(merged, 95)
        print("Keystroke → keyword results: p50 \(RetrievalMetrics.percentile(keyword, 50)) ms, p95 \(keywordP95) ms")
        print("Keystroke → merged results: p50 \(RetrievalMetrics.percentile(merged, 50)) ms, p95 \(mergedP95) ms")
        #expect(keywordP95 <= Budget.keywordSearch)
        #expect(mergedP95 <= Budget.mergedResults)
    }

    /// 25k files × 4 chunks of plausible text, each with a vector.
    static func populate(_ writer: IndexWriter, space: VectorSpace) async throws {
        let words = """
            quarterly revenue chart region europe asia pricing acme pitch deck meeting notes deadline client contract \
            beach sunset hotel receipt flight confirmation recipe tomato basil garlic launch plan marketing press \
            engineering onboarding sprint retro flaky tests budget finance hiring support design review mockup
            """.split(separator: " ").map(String.init)
        let source = try await writer.addSource(path: "/perf", bookmark: nil)
        let files = (0..<(chunkCount / 4)).map { index in
            ScannedFile(
                path: "/perf/\(index / 500)/file-\(index).txt", kind: .document, contentType: .plainText,
                size: Int64(index), modified: Date(timeIntervalSince1970: Double(index)))
        }
        _ = try await writer.reconcile(sourceID: source, scanned: files)
        var generator = SystemRandomNumberGenerator()
        while true {
            let claimed = try await writer.claimPending(limit: 500, kinds: [.document])
            if claimed.isEmpty { break }
            for record in claimed {
                let chunks = (0..<4).map { ordinal in
                    let text = (0..<60).map { _ in words.randomElement(using: &generator) ?? "" }.joined(separator: " ")
                    let vector = Embedding(
                        normalizing: (0..<space.dimension).map { _ in Float.random(in: -1...1, using: &generator) }, space: space)
                    return ChunkWrite(
                        ordinal: ordinal, locator: .text(start: 0, end: text.count), text: text, thumbnail: nil, vector: vector.values)
                }
                _ = try await writer.commit(fileID: record.id, contentHash: "h\(record.id.rawValue)", space: space, chunks: chunks)
            }
        }
        try await writer.optimize()
    }
}

/// A fast deterministic encoder, so the merged-results budget measures the search path,
/// not the model (the model has its own budget above).
private struct PerfEncoder: EmbeddingProvider {
    let space: VectorSpace
    var descriptor: ModelDescriptor {
        ModelDescriptor(
            id: "perf", version: "1", displayName: "Perf", dimensions: space.dimension,
            supportedDimensions: [space.dimension], modalities: [.text], license: "test", allowsCommercialUse: true)
    }

    func embed(_ batch: [EmbeddingInput], purpose: EmbeddingPurpose) async throws -> [Embedding] {
        batch.map { _ in Embedding(normalizing: (0..<space.dimension).map { Float($0 % 5) - 2 }, space: descriptor.space) }
    }
}

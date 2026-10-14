import Foundation
import GlintCore
import GlintEmbedding
import GlintExtractors
import GlintIndexer
import GlintSearch
import GlintStore

/// Indexes a corpus with a candidate build and scores every golden query.
struct EvalRunner {
    let corpus: URL
    let queries: [EvalQuery]
    let provider: any EmbeddingProvider
    /// Overrides the model's similarity margin when set (`.some(nil)` turns it off), for tuning.
    var similarityMargin: Float??
    var indexerOptions = IndexerOptions()
    /// Partial keyword matches kept in the final phase (`.some(nil)`: all, at full weight).
    var looseKeywordLimit: Int??
    /// Overrides the model's minimum z-score when set (`.some(nil)` turns it off).
    var minimumZScore: Float??
    /// Overrides the model's minimum robust z-score when set (`.some(nil)` turns it off).
    var minimumRobustZScore: Float??
    /// Overrides the model's confident similarity when set (`.some(nil)` turns it off).
    var confidentSimilarity: Float??
    /// Ranker settings under test (fusion, per-file fusion, weights).
    var ranker = HybridRanker()
    /// Lean each query's weights by how it reads (`QueryStyle`).
    var adaptsWeights = true
    /// Writes, per query, where every relevant file ranks in the raw semantic and keyword lists
    /// before any cutoff, to tell a model miss from a filter miss.
    var diagnosePath: URL?

    func run() async throws -> EvalReport {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("glint-eval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let paths = AppPaths(root: work)
        try paths.createDirectories()

        let writer = try IndexWriter(url: paths.database)
        let gate = PriorityGate()
        let vectorIndex = FlatVectorIndex(space: provider.descriptor.space)
        let thumbnails = ThumbnailStore(directory: paths.thumbnails)
        let indexer = Indexer(
            writer: writer, extractors: ExtractorRegistry.standard(transcriber: nil).extractors, provider: provider,
            vectorIndex: vectorIndex, gate: gate, thumbnails: thumbnails, power: FixedPowerMonitor(),
            options: indexerOptions
        )
        let reader = try IndexReader(url: paths.database)
        let queryEncoder = GatedQueryEncoder(provider: provider, gate: gate)
        let engine = SearchEngine(
            reader: reader, vectorIndex: vectorIndex,
            encoder: MarginOverride(
                base: queryEncoder, margin: similarityMargin, zScore: minimumZScore,
                robustZScore: minimumRobustZScore, confident: confidentSimilarity),
            thumbnails: thumbnails, ranker: ranker, looseKeywordLimit: looseKeywordLimit ?? 3,
            adaptsWeights: adaptsWeights
        )

        let indexing = Stopwatch()
        let root = FileScanner.canonicalPath(corpus)
        try await indexer.addSource(corpus)
        await indexer.drain()
        let status = await indexer.currentStatus()
        let indexingSeconds = indexing.milliseconds / 1_000
        print(String(format: "Indexed %d files in %.1f s (%d failed)", status.totalIndexed, indexingSeconds, status.failed))

        // Warm the query path once so the first query's latency is representative.
        _ = try? await engine.mergedResults(for: SearchQuery(text: "warm up"))

        var outcomes: [QueryOutcome] = []
        for query in queries {
            outcomes.append(try await outcome(of: query, engine: engine, root: root))
        }
        try await writeDiagnostics(engine: engine, reader: reader, encoder: queryEncoder, root: root)
        return report(outcomes, corpusFiles: status.totalIndexed, indexingSeconds: indexingSeconds)
    }

    private func outcome(of query: EvalQuery, engine: SearchEngine, root: String) async throws -> QueryOutcome {
        let stopwatch = Stopwatch()
        let results = try await engine.mergedResults(for: SearchQuery(text: query.text))
        let latency = stopwatch.milliseconds
        let ignored = Set(query.ignored ?? [])
        let ranked = results.items.map { relativePath($0.file.path, root: root) }.filter { !ignored.contains($0) }
        let hits = ranked.filter { (query.relevant[$0] ?? 0) > 0 }.count
        let wanted = query.relevant.values.filter { $0 > 0 }.count
        return QueryOutcome(
            id: query.id,
            kind: kind(of: query),
            recallAt10: RetrievalMetrics.recall(ranked: ranked, relevant: query.relevant),
            reciprocalRank: RetrievalMetrics.reciprocalRank(ranked: ranked, relevant: query.relevant),
            ndcgAt10: RetrievalMetrics.ndcg(ranked: ranked, relevant: query.relevant),
            latencyMilliseconds: latency,
            top: Array(ranked.prefix(5)),
            mustPass: query.mustPass ?? false,
            returned: ranked.count,
            precision: ranked.isEmpty ? (query.isNegative ? 1 : 0) : Double(hits) / Double(ranked.count),
            recall: wanted == 0 ? nil : Double(hits) / Double(wanted),
            isNegative: query.isNegative
        )
    }

    private func writeDiagnostics(engine: SearchEngine, reader: IndexReader, encoder: GatedQueryEncoder, root: String) async throws {
        guard let diagnosePath else { return }
        let diagnostics = try await diagnose(engine: engine, reader: reader, encoder: encoder, root: root)
        try JSONEncoder.pretty.encode(diagnostics).write(to: diagnosePath)
    }

    /// Raw rankings before any cutoff, for every relevant file of every positive query.
    private func diagnose(engine: SearchEngine, reader: IndexReader, encoder: GatedQueryEncoder, root: String) async throws
        -> [QueryDiagnostic]
    {
        var results: [QueryDiagnostic] = []
        for query in queries where !query.isNegative {
            let embedding = try await encoder.encode(query: query.text)
            let (hits, statistics) = try await engine.vectorIndex.searchWithStatistics(embedding, limit: 1_000_000, filter: .none)
            var bestPerFile: [FileID: Float] = [:]
            for hit in hits where bestPerFile[hit.fileID] == nil { bestPerFile[hit.fileID] = hit.score }
            let semanticOrder = bestPerFile.sorted { $0.value > $1.value }
            let fts = FTSQuery(query.text, allowsPrefix: false)
            func ranks(_ match: String?, names: Bool) async throws -> [FileID: Int] {
                guard let match else { return [:] }
                let hits = names ? try await reader.nameMatches(match, limit: 5_000) : try await reader.chunkMatches(match, limit: 5_000)
                var ranks: [FileID: Int] = [:]
                for hit in hits where ranks[hit.fileID] == nil { ranks[hit.fileID] = ranks.count + 1 }
                return ranks
            }
            let keywordAll = try await ranks(fts.all, names: false)
            let keywordAny = try await ranks(fts.any, names: false)
            let nameAny = try await ranks(fts.any, names: true)
            let ids = semanticOrder.map(\.key)
            let records = try await reader.files(ids)
            let pathOf = Dictionary(uniqueKeysWithValues: records.map { ($0.key, relativePath($0.value.path, root: root)) })
            let fileByPath = Dictionary(pathOf.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
            let semanticRank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset + 1) })
            let relevant = query.relevant.filter { $0.value > 0 }.keys.map { path -> RelevantDiagnostic in
                let id = fileByPath[path]
                return RelevantDiagnostic(
                    path: path, semanticRank: id.flatMap { semanticRank[$0] }, cosine: id.flatMap { bestPerFile[$0] },
                    keywordAllRank: id.flatMap { keywordAll[$0] }, keywordAnyRank: id.flatMap { keywordAny[$0] },
                    nameRank: id.flatMap { nameAny[$0] })
            }
            results.append(
                QueryDiagnostic(
                    id: query.id, text: query.text, bestCosine: semanticOrder.first?.value,
                    top: semanticOrder.prefix(10).map { pathOf[$0.key] ?? "?" },
                    topCosines: semanticOrder.prefix(10).map(\.value), mean: statistics?.mean, deviation: statistics?.deviation,
                    median: statistics?.median, robustDeviation: statistics?.robustDeviation, keywordAllCount: keywordAll.count,
                    keywordAnyCount: keywordAny.count, relevant: relevant))
        }
        return results
    }

    private func report(_ outcomes: [QueryOutcome], corpusFiles: Int, indexingSeconds: Double) -> EvalReport {
        let negatives = outcomes.filter { $0.isNegative == true }
        let positives = outcomes.filter { $0.isNegative != true }
        var perKind: [String: Scores] = [:]
        for (kind, group) in Dictionary(grouping: positives, by: \.kind) { perKind[kind] = scores(group) }
        let latencies = outcomes.map(\.latencyMilliseconds)
        return EvalReport(
            model: provider.descriptor.space.description,
            date: Date(),
            corpusFiles: corpusFiles,
            indexingSeconds: indexingSeconds,
            overall: scores(positives),
            perKind: perKind,
            negatives: negatives.isEmpty
                ? nil
                : NegativeScores(
                    queries: negatives.count,
                    emptyRate: Double(negatives.filter { $0.returned == 0 }.count) / Double(negatives.count),
                    averageReturned: Double(negatives.map { $0.returned ?? 0 }.reduce(0, +)) / Double(negatives.count)),
            latencyP50Milliseconds: RetrievalMetrics.percentile(latencies, 50),
            latencyP95Milliseconds: RetrievalMetrics.percentile(latencies, 95),
            outcomes: outcomes
        )
    }

    private func scores(_ outcomes: [QueryOutcome]) -> Scores {
        let count = Double(max(outcomes.count, 1))
        return Scores(
            queries: outcomes.count,
            recallAt10: outcomes.map(\.recallAt10).reduce(0, +) / count,
            mrr: outcomes.map(\.reciprocalRank).reduce(0, +) / count,
            ndcgAt10: outcomes.map(\.ndcgAt10).reduce(0, +) / count,
            precision: outcomes.map { $0.precision ?? 0 }.reduce(0, +) / count,
            recall: outcomes.map { $0.recall ?? 0 }.reduce(0, +) / count,
            f1: outcomes.map { outcome in
                let p = outcome.precision ?? 0
                let r = outcome.recall ?? 0
                return p + r > 0 ? 2 * p * r / (p + r) : 0
            }.reduce(0, +) / count
        )
    }

    /// A query's media type is the kind of its best-graded relevant file.
    private func kind(of query: EvalQuery) -> String {
        if query.isNegative { return "negative" }
        guard let best = query.relevant.max(by: { $0.value < $1.value })?.key else { return "unknown" }
        let url = corpus.appendingPathComponent(best)
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return type.flatMap(MediaKind.init(contentType:))?.rawValue ?? "unknown"
    }

    private func relativePath(_ path: String, root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

/// Wraps the model's query encoder with a different similarity margin or z-scores.
private struct MarginOverride: QueryEncoding {
    let base: any QueryEncoding
    let margin: Float??
    let zScore: Float??
    let robustZScore: Float??
    let confident: Float??

    var space: VectorSpace { base.space }
    var minimumSimilarity: Float { base.minimumSimilarity }
    var similarityMargin: Float? { margin ?? base.similarityMargin }
    var minimumZScore: Float? { zScore ?? base.minimumZScore }
    var minimumRobustZScore: Float? { robustZScore ?? base.minimumRobustZScore }
    var confidentSimilarity: Float? { confident ?? base.confidentSimilarity }
    var limitsLooseKeywords: Bool { base.limitsLooseKeywords }
    func encode(query: String) async throws -> Embedding { try await base.encode(query: query) }
}

/// Where a query's relevant files sit before any cutoff.
struct QueryDiagnostic: Codable {
    var id: String
    var text: String
    var bestCosine: Float?
    var top: [String]
    var topCosines: [Float]
    var mean: Float?
    var deviation: Float?
    var median: Float?
    var robustDeviation: Float?
    var keywordAllCount: Int
    var keywordAnyCount: Int
    var relevant: [RelevantDiagnostic]
}

struct RelevantDiagnostic: Codable {
    var path: String
    var semanticRank: Int?
    var cosine: Float?
    var keywordAllRank: Int?
    var keywordAnyRank: Int?
    var nameRank: Int?
}

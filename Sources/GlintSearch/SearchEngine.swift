import Foundation
import GlintCore
import GlintStore

/// Errors from the search path.
public enum SearchError: GlintError, Equatable {
    /// Semantic search was requested but no query encoder is loaded.
    case encoderUnavailable
    /// "Find similar" was asked for a file with nothing to compare.
    case noExample

    public var category: ErrorCategory {
        switch self {
        case .encoderUnavailable: .model
        case .noExample: .unsupported
        }
    }

    public var description: String {
        switch self {
        case .encoderUnavailable: "The query encoder is not loaded"
        case .noExample: "Nothing to compare with"
        }
    }
}

/// The interactive search path. Runs in its own actor and reads through its own connection,
/// so it never waits on the indexer's writer.
///
/// Results come in two phases: `keywordResults` renders on the keystroke, and
/// `mergedResults` fuses in semantic matches once the query embedding returns.
public actor SearchEngine {
    public private(set) var vectorIndex: FlatVectorIndex
    private let reader: IndexReader
    private var encoder: (any QueryEncoding)?
    private var exampleEncoder: (any ExampleEncoder)?
    private let thumbnails: ThumbnailStore
    private let gate: FeatureGateBox
    private var ranker: HybridRanker
    private let now: @Sendable () -> Date
    private var keywordCache: KeywordCache?

    /// Maximum files returned per query.
    public let resultLimit: Int

    public init(
        reader: IndexReader,
        vectorIndex: FlatVectorIndex,
        encoder: (any QueryEncoding)?,
        exampleEncoder: (any ExampleEncoder)? = nil,
        thumbnails: ThumbnailStore,
        gate: FeatureGateBox,
        ranker: HybridRanker = HybridRanker(),
        resultLimit: Int = 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.reader = reader
        self.vectorIndex = vectorIndex
        self.encoder = encoder
        self.exampleEncoder = exampleEncoder
        self.thumbnails = thumbnails
        self.gate = gate
        self.ranker = ranker
        if let encoder {
            self.ranker.minimumSimilarity = encoder.minimumSimilarity
            self.ranker.similarityMargin = encoder.similarityMargin
            self.ranker.minimumZScore = encoder.minimumZScore
        }
        self.resultLimit = resultLimit
        self.now = now
    }

    /// Switches the semantic path to another model's space and loads the vectors already stored
    /// in it. Files not yet re-embedded keep matching by keyword until the indexer reaches them.
    public func switchModel(
        encoder newEncoder: any QueryEncoding, exampleEncoder newExampleEncoder: (any ExampleEncoder)?,
        vectorIndex newIndex: FlatVectorIndex
    ) async throws {
        encoder = newEncoder
        exampleEncoder = newExampleEncoder
        ranker.minimumSimilarity = newEncoder.minimumSimilarity
        ranker.similarityMargin = newEncoder.similarityMargin
        ranker.minimumZScore = newEncoder.minimumZScore
        vectorIndex = newIndex
        keywordCache = nil
        try await loadVectors()
    }

    /// Loads every stored vector of the index's space into the resident matrix. Returns the count.
    @discardableResult
    public func loadVectors(pageSize: Int = 5_000) async throws -> Int {
        let space = vectorIndex.space
        var after: ChunkID?
        var total = 0
        while true {
            let page = try await reader.vectors(in: space, after: after, limit: pageSize)
            guard let last = page.last else { break }
            try await vectorIndex.upsert(page)
            total += page.count
            after = last.chunkID
        }
        Log.search.info("Loaded \(total, privacy: .public) vectors into the resident index")
        return total
    }

    // MARK: Text search

    /// Phase one: keyword and file-name matches only. Fast enough to run on every keystroke.
    public func keywordResults(for query: SearchQuery) async throws -> SearchResults {
        let stopwatch = Stopwatch()
        let state = Signposts.search.beginInterval(Signposts.Name.keywordSearch)
        defer { Signposts.search.endInterval(Signposts.Name.keywordSearch, state) }
        guard !query.isEmpty else { return .empty(query, phase: .keyword) }

        let (chunks, names) = try await keywordHits(for: query, prefix: true)
        let ranked = ranker.rank(semantic: [], keyword: chunks, names: names, attributes: attributes(chunks + names), now: now())
        let items = try await hydrate(ranked, terms: FTSQuery(query.text).terms)
        return SearchResults(query: query, phase: .keyword, items: items, elapsedMilliseconds: stopwatch.milliseconds)
    }

    /// Phase two: keyword and semantic matches fused. Falls back to keyword results when no
    /// encoder is loaded, so search keeps working while a model downloads.
    public func mergedResults(for query: SearchQuery) async throws -> SearchResults {
        let stopwatch = Stopwatch()
        let state = Signposts.search.beginInterval(Signposts.Name.mergedResults)
        defer { Signposts.search.endInterval(Signposts.Name.mergedResults, state) }
        guard !query.isEmpty else { return .empty(query) }

        // Once a model is loaded the last word is matched whole: by now the user has stopped
        // typing, and semantic search covers related words better than a prefix would.
        let (chunks, names) = try await keywordHits(for: query, prefix: encoder == nil)
        var semantic: [ScoredChunk] = []
        var statistics: ScoreStatistics?
        if let encoder {
            let embedding = try await encoder.encode(query: query.text)
            try Task.checkCancellation()
            (semantic, statistics) = try await vectorIndex.searchWithStatistics(embedding, limit: resultLimit * 4, filter: query.filter)
        }
        try Task.checkCancellation()
        let ranked = ranker.rank(
            semantic: semantic, keyword: chunks, names: names, attributes: attributes(chunks + names), statistics: statistics,
            now: now())
        let items = try await hydrate(ranked, terms: FTSQuery(query.text).terms)
        return SearchResults(query: query, phase: .merged, items: items, elapsedMilliseconds: stopwatch.milliseconds)
    }

    // MARK: Find similar

    /// Files similar to an indexed file.
    public func similar(to fileID: FileID, filter: SearchFilter = .none) async throws -> SearchResults {
        let vectors = await vectorIndex.vectors(of: fileID)
        var filter = filter
        filter.excludedFiles.insert(fileID)
        return try await similar(toVectors: vectors, filter: filter)
    }

    /// Files similar to any file on disk; uses stored vectors when the file is indexed.
    public func similar(toFileAt url: URL, filter: SearchFilter = .none) async throws -> SearchResults {
        if let record = try await reader.file(atPath: url.path), record.status == .indexed {
            return try await similar(to: record.id, filter: filter)
        }
        guard let exampleEncoder else { throw SearchError.encoderUnavailable }
        let embeddings = try await exampleEncoder.embeddings(forFileAt: url)
        return try await similar(toVectors: embeddings.map(\.values), filter: filter)
    }

    private func similar(toVectors vectors: [[Float]], filter: SearchFilter) async throws -> SearchResults {
        let space = vectorIndex.space
        guard let first = vectors.first else { throw SearchError.noExample }
        var mean = [Float](repeating: 0, count: first.count)
        for vector in vectors { for index in mean.indices where index < vector.count { mean[index] += vector[index] } }
        guard mean.count == space.dimension else { throw SearchError.noExample }
        let query = Embedding(normalizing: mean, space: space)
        let semantic = try await vectorIndex.search(query, limit: resultLimit * 4, filter: filter)
        var ranker = ranker
        ranker.recencyBoost = 0
        // "Find similar" is for browsing neighbours, not deciding what matches.
        ranker.similarityMargin = nil
        ranker.minimumZScore = nil
        let ranked = ranker.rank(semantic: semantic, keyword: [], names: [], attributes: [:], now: now())
        let items = try await hydrate(ranked, terms: [])
        return SearchResults(query: SearchQuery(text: "", filter: filter), phase: .merged, items: items, elapsedMilliseconds: 0)
    }

    // MARK: Library

    /// Recently modified files for the main window's library views.
    public func recent(kinds: Set<MediaKind>, limit: Int, offset: Int = 0) async throws -> [SearchResult] {
        let records = try await reader.recentFiles(kinds: kinds, limit: limit, offset: offset)
        let firstChunks = try await reader.firstChunks(of: records.map(\.id))
        let snapshot = gate.current
        return records.map { record in
            let chunk = firstChunks[record.id]
            return SearchResult(
                file: FileSummary(record),
                match: MatchDetail(
                    chunkID: chunk?.id, locator: chunk?.locator ?? .whole,
                    snippet: chunk?.text.map { Snippet.make(from: $0, terms: []) },
                    thumbnailURL: chunk?.thumbnail.map(thumbnails.url(forRelativePath:))
                ),
                score: 0, sources: [], isLocked: !snapshot.allows(record.kind)
            )
        }
    }

    // MARK: Helpers

    private func keywordHits(for query: SearchQuery, prefix: Bool) async throws -> ([KeywordHit], [KeywordHit]) {
        if let keywordCache, keywordCache.query == query, keywordCache.prefix == prefix {
            return (keywordCache.chunks, keywordCache.names)
        }
        let fts = FTSQuery(query.text, allowsPrefix: prefix)
        guard let all = fts.all else { return ([], []) }
        let fetchLimit = resultLimit * 3
        var chunks = try await reader.chunkMatches(all, limit: fetchLimit)
        var names = try await reader.nameMatches(all, limit: fetchLimit)
        // Natural-language queries rarely match every word; fall back to any word.
        if chunks.count + names.count < 5, fts.terms.count > 1, let any = fts.any {
            let seen = Set(chunks.compactMap(\.chunkID))
            chunks += try await reader.chunkMatches(any, limit: fetchLimit).filter { !seen.contains($0.chunkID ?? ChunkID(-1)) }
            let seenNames = Set(names.map(\.fileID))
            names += try await reader.nameMatches(any, limit: fetchLimit).filter { !seenNames.contains($0.fileID) }
        }
        chunks = chunks.filter { query.filter.matches(fileID: $0.fileID, attributes: $0.attributes) }
        names = names.filter { query.filter.matches(fileID: $0.fileID, attributes: $0.attributes) }
        keywordCache = KeywordCache(query: query, prefix: prefix, chunks: chunks, names: names)
        return (chunks, names)
    }

    private func attributes(_ hits: [KeywordHit]) -> [FileID: FileAttributes] {
        Dictionary(hits.map { ($0.fileID, $0.attributes) }, uniquingKeysWith: { first, _ in first })
    }

    private func hydrate(_ ranked: [RankedFile], terms: [String]) async throws -> [SearchResult] {
        let top = Array(ranked.prefix(resultLimit))
        let files = try await reader.files(top.map(\.fileID))
        let chunks = try await reader.chunks(top.compactMap(\.bestChunk))
        let fallbacks = try await reader.firstChunks(of: top.filter { $0.bestChunk == nil }.map(\.fileID))
        let snapshot = gate.current

        return top.compactMap { ranked -> SearchResult? in
            guard let record = files[ranked.fileID] else { return nil }
            let chunk = ranked.bestChunk.flatMap { chunks[$0] } ?? fallbacks[ranked.fileID]
            let snippet = chunk?.text.map { Snippet.make(from: $0, terms: terms) }
            return SearchResult(
                file: FileSummary(record),
                match: MatchDetail(
                    chunkID: chunk?.id,
                    locator: chunk?.locator ?? .whole,
                    snippet: snippet?.text.isEmpty == false ? snippet : nil,
                    thumbnailURL: chunk?.thumbnail.map(thumbnails.url(forRelativePath:))
                ),
                score: ranked.score,
                sources: ranked.sources,
                isLocked: !snapshot.allows(record.kind)
            )
        }
    }
}

/// The last query's keyword hits, reused while only the semantic phase changes.
private struct KeywordCache {
    let query: SearchQuery
    let prefix: Bool
    let chunks: [KeywordHit]
    let names: [KeywordHit]
}

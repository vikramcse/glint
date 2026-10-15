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
    private var ranker: HybridRanker
    private let now: @Sendable () -> Date
    private var keywordCache: KeywordCache?

    /// Maximum files returned per query.
    public let resultLimit: Int
    /// With a model that `limitsLooseKeywords`, how many partial (any-word) keyword matches the
    /// final phase keeps; they also count for less in the ranking (`HybridRanker.looseKeywordWeight`). Partial
    /// matches of common words ("score", "error") otherwise flood natural-language queries and
    /// push the real match down (SciFact: MRR 0.61 -> 0.80, Recall@10 0.82 -> 0.93 with them
    /// limited). `nil` keeps them all at full weight, as without a model or with a weaker one.
    public let looseKeywordLimit: Int?
    /// Leans each query's fusion towards keywords or meaning by how it reads (`QueryStyle`).
    public let adaptsWeights: Bool

    public init(
        reader: IndexReader,
        vectorIndex: FlatVectorIndex,
        encoder: (any QueryEncoding)?,
        exampleEncoder: (any ExampleEncoder)? = nil,
        thumbnails: ThumbnailStore,
        ranker: HybridRanker = HybridRanker(),
        resultLimit: Int = 60,
        looseKeywordLimit: Int? = 3,
        adaptsWeights: Bool = true,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.looseKeywordLimit = looseKeywordLimit
        self.adaptsWeights = adaptsWeights
        self.reader = reader
        self.vectorIndex = vectorIndex
        self.encoder = encoder
        self.exampleEncoder = exampleEncoder
        self.thumbnails = thumbnails
        self.ranker = ranker
        if let encoder {
            self.ranker.minimumSimilarity = encoder.minimumSimilarity
            self.ranker.similarityMargin = encoder.similarityMargin
            self.ranker.minimumZScore = encoder.minimumZScore
            self.ranker.minimumRobustZScore = encoder.minimumRobustZScore
            self.ranker.confidentSimilarity = encoder.confidentSimilarity
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
        ranker.minimumRobustZScore = newEncoder.minimumRobustZScore
        ranker.confidentSimilarity = newEncoder.confidentSimilarity
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
        if query.namesOnly { return try await nameResults(for: query, phase: .keyword, stopwatch: stopwatch) }

        let hits = try await keywordHits(for: query, prefix: true)
        let chunks = hits.chunks + hits.looseChunks
        let names = hits.names + hits.looseNames
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
        if query.namesOnly { return try await nameResults(for: query, phase: .merged, stopwatch: stopwatch) }

        // Once a model is loaded the last word is matched whole: by now the user has stopped
        // typing, and semantic search covers related words better than a prefix would.
        let hits = try await keywordHits(for: query, prefix: encoder == nil)
        var chunks = hits.chunks
        var names = hits.names
        var looseChunks: [KeywordHit] = []
        var looseNames: [KeywordHit] = []
        if encoder?.limitsLooseKeywords != true || looseKeywordLimit == nil {
            chunks += hits.looseChunks
            names += hits.looseNames
        } else if let limit = looseKeywordLimit {
            looseChunks = Array(hits.looseChunks.prefix(limit))
            looseNames = Array(hits.looseNames.prefix(limit))
        }
        // Snapshot the model state: a model switch during the await below must not score this
        // query's embedding against another model's vectors or thresholds.
        let index = vectorIndex
        var ranker = ranker
        let (semantic, statistics) = try await semanticMatches(for: query, in: index)
        try Task.checkCancellation()
        if adaptsWeights {
            let weights = QueryStyle(query.text).weights
            ranker.semanticWeight *= weights.semantic
            ranker.keywordWeight *= weights.keyword
            ranker.nameWeight *= weights.keyword
        }
        let kinds = await index.kinds(of: semantic.map(\.fileID))
        let ranked = ranker.rank(
            semantic: semantic, keyword: chunks, names: names, looseKeyword: looseChunks, looseNames: looseNames,
            attributes: attributes(chunks + names + looseChunks + looseNames), statistics: statistics, kinds: kinds,
            now: now())
        let items = try await hydrate(ranked, terms: FTSQuery(query.text).terms)
        return SearchResults(query: query, phase: .merged, items: items, elapsedMilliseconds: stopwatch.milliseconds)
    }

    /// Semantic matches for the query in `index`; none when no encoder is loaded or the
    /// encoder's space no longer matches the index.
    private func semanticMatches(
        for query: SearchQuery, in index: FlatVectorIndex
    ) async throws -> ([ScoredChunk], ScoreStatistics?) {
        guard let encoder else { return ([], nil) }
        let embedding = try await encoder.encode(query: query.text)
        try Task.checkCancellation()
        guard embedding.space == index.space else { return ([], nil) }
        return try await index.searchWithStatistics(embedding, limit: resultLimit * 4, filter: query.filter)
    }

    /// File-name search: every query word must appear somewhere in the name. Files not yet
    /// indexed match too.
    private func nameResults(for query: SearchQuery, phase: SearchPhase, stopwatch: Stopwatch) async throws -> SearchResults {
        let words = query.text.split(whereSeparator: \.isWhitespace).map(String.init)
        // Fetch extra so the kind, folder and date filters still leave a full page.
        let hits = try await reader.filesNamed(containing: words, limit: query.filter.isEmpty ? resultLimit : resultLimit * 20)
            .filter { query.filter.matches(fileID: $0.fileID, attributes: $0.attributes) }
            .prefix(resultLimit)
        let ranked = hits.enumerated().map { index, hit in
            RankedFile(fileID: hit.fileID, bestChunk: nil, score: 1 / Double(index + 1), sources: .name, similarity: nil)
        }
        let items = try await hydrate(ranked, terms: words)
        return SearchResults(query: query, phase: phase, items: items, elapsedMilliseconds: stopwatch.milliseconds)
    }

    // MARK: Find similar

    /// Files similar to an indexed file.
    public func similar(to fileID: FileID, filter: SearchFilter = .none) async throws -> SearchResults {
        let index = vectorIndex
        let vectors = await index.vectors(of: fileID)
        var filter = filter
        filter.excludedFiles.insert(fileID)
        return try await similar(toVectors: vectors, in: index, filter: filter)
    }

    /// Files similar to the indexed file at `path`, from its stored vectors; nil when no indexed
    /// file has that path. Never opens the file.
    public func similar(toIndexedFileAt path: String, filter: SearchFilter = .none) async throws -> SearchResults? {
        guard let record = try await reader.file(atPath: path), record.status == .indexed else { return nil }
        return try await similar(to: record.id, filter: filter)
    }

    /// Files similar to any file on disk; uses stored vectors when the file is indexed.
    public func similar(toFileAt url: URL, filter: SearchFilter = .none) async throws -> SearchResults {
        if let results = try await similar(toIndexedFileAt: url.path, filter: filter) { return results }
        guard let exampleEncoder else { throw SearchError.encoderUnavailable }
        let index = vectorIndex
        let embeddings = try await exampleEncoder.embeddings(forFileAt: url)
        // A model switch during the encode leaves embeddings from the old space; don't mix them in.
        let vectors = embeddings.filter { $0.space == index.space }.map(\.values)
        return try await similar(toVectors: vectors, in: index, filter: filter)
    }

    private func similar(toVectors vectors: [[Float]], in index: FlatVectorIndex, filter: SearchFilter) async throws -> SearchResults {
        let space = index.space
        guard let first = vectors.first else { throw SearchError.noExample }
        var mean = [Float](repeating: 0, count: first.count)
        for vector in vectors { for index in mean.indices where index < vector.count { mean[index] += vector[index] } }
        guard mean.count == space.dimension else { throw SearchError.noExample }
        let query = Embedding(normalizing: mean, space: space)
        let semantic = try await index.search(query, limit: resultLimit * 4, filter: filter)
        var ranker = ranker
        ranker.recencyBoost = 0
        // "Find similar" is for browsing neighbours, not deciding what matches.
        ranker.similarityMargin = nil
        ranker.minimumZScore = nil
        ranker.confidentSimilarity = nil
        let ranked = ranker.rank(semantic: semantic, keyword: [], names: [], attributes: [:], now: now())
        let items = try await hydrate(ranked, terms: [])
        return SearchResults(query: SearchQuery(text: "", filter: filter), phase: .merged, items: items, elapsedMilliseconds: 0)
    }

    // MARK: Library

    /// Files for the main window's library views, newest first unless `sort` says otherwise.
    public func recent(
        kinds: Set<MediaKind>, folder: String? = nil, sort: ResultSort = .newestFirst, limit: Int, offset: Int = 0
    ) async throws -> [SearchResult] {
        let records = try await reader.recentFiles(kinds: kinds, folder: folder, sort: sort, limit: limit, offset: offset)
        let firstChunks = try await reader.firstChunks(of: records.map(\.id))
        return records.map { record in
            let chunk = firstChunks[record.id]
            return SearchResult(
                file: FileSummary(record),
                match: MatchDetail(
                    chunkID: chunk?.id, locator: chunk?.locator ?? .whole,
                    snippet: chunk?.text.map { Snippet.make(from: $0, terms: []) },
                    thumbnailURL: chunk?.thumbnail.map(thumbnails.url(forRelativePath:))
                ),
                score: 0, sources: []
            )
        }
    }

    // MARK: People

    /// People for the People view: everyone seen in at least `minimumFiles` files, and everyone named.
    public func people(minimumFiles: Int = 2) async throws -> [PersonSummary] {
        try await reader.people(minimumFiles: minimumFiles).map { row in
            PersonSummary(
                id: row.id, name: row.name, fileCount: row.fileCount,
                faceThumbnailURL: row.faceThumbnail.map(thumbnails.url(forRelativePath:)))
        }
    }

    /// The photos and videos a person appears in, newest first, each at the moment their face
    /// is clearest.
    public func files(of person: PersonID) async throws -> [SearchResult] {
        try await reader.files(of: person).map { record, chunk in
            SearchResult(
                file: FileSummary(record),
                match: MatchDetail(
                    chunkID: chunk?.id, locator: chunk?.locator ?? .whole, snippet: nil,
                    thumbnailURL: chunk?.thumbnail.map(thumbnails.url(forRelativePath:))
                ),
                score: 0, sources: []
            )
        }
    }

    // MARK: Helpers

    /// Keyword matches: `chunks` and `names` match every query word; `loose` lists match only
    /// some (filled when few files match them all and the query has several words).
    fileprivate struct KeywordHits {
        var chunks: [KeywordHit] = []
        var names: [KeywordHit] = []
        var looseChunks: [KeywordHit] = []
        var looseNames: [KeywordHit] = []
    }

    private func keywordHits(for query: SearchQuery, prefix: Bool) async throws -> KeywordHits {
        let generation = await vectorIndex.generation
        if let keywordCache, keywordCache.query == query, keywordCache.prefix == prefix, keywordCache.generation == generation,
            now().timeIntervalSince(keywordCache.created) < Self.keywordCacheLifetime
        {
            return keywordCache.hits
        }
        let fts = FTSQuery(query.text, allowsPrefix: prefix)
        guard let all = fts.all else { return KeywordHits() }
        // Fetch extra so the kind, folder and date filters still leave a full page.
        let fetchLimit = query.filter.isEmpty ? resultLimit * 3 : resultLimit * 20
        let allowed = { (hit: KeywordHit) in query.filter.matches(fileID: hit.fileID, attributes: hit.attributes) }
        var hits = KeywordHits()
        hits.chunks = try await reader.chunkMatches(all, limit: fetchLimit).filter(allowed)
        hits.names = try await reader.nameMatches(all, limit: fetchLimit).filter(allowed)
        // Natural-language queries rarely match every word; also look for any word.
        if hits.chunks.count + hits.names.count < 5, fts.terms.count > 1, let any = fts.any {
            let seen = Set(hits.chunks.compactMap(\.chunkID))
            hits.looseChunks = try await reader.chunkMatches(any, limit: fetchLimit)
                .filter { allowed($0) && !seen.contains($0.chunkID ?? ChunkID(-1)) }
            let seenNames = Set(hits.names.map(\.fileID))
            hits.looseNames = try await reader.nameMatches(any, limit: fetchLimit).filter { allowed($0) && !seenNames.contains($0.fileID) }
        }
        keywordCache = KeywordCache(query: query, prefix: prefix, generation: generation, created: now(), hits: hits)
        return hits
    }

    /// How long cached keyword hits stay valid. The vector index's generation catches commits and
    /// removals; this bounds staleness from anything that changes the index without touching it.
    static let keywordCacheLifetime: TimeInterval = 30

    private func attributes(_ hits: [KeywordHit]) -> [FileID: FileAttributes] {
        Dictionary(hits.map { ($0.fileID, $0.attributes) }, uniquingKeysWith: { first, _ in first })
    }

    private func hydrate(_ ranked: [RankedFile], terms: [String]) async throws -> [SearchResult] {
        let top = Array(ranked.prefix(resultLimit))
        let files = try await reader.files(top.map(\.fileID))
        let chunks = try await reader.chunks(top.compactMap(\.bestChunk))
        let fallbacks = try await reader.firstChunks(of: top.filter { $0.bestChunk == nil }.map(\.fileID))

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
                sources: ranked.sources
            )
        }
    }
}

/// The last query's keyword hits, reused while only the semantic phase changes and the index
/// hasn't changed.
private struct KeywordCache {
    let query: SearchQuery
    let prefix: Bool
    let generation: Int
    let created: Date
    let hits: SearchEngine.KeywordHits
}

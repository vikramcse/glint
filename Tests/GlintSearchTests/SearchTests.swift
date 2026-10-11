import Foundation
import GlintCore
import GlintStore
import Testing

@testable import GlintSearch

private let space = VectorSpace(modelID: "test/1", dimension: 8)

private func unit(_ index: Int, dimension: Int = 8) -> [Float] {
    var vector = [Float](repeating: 0, count: dimension)
    vector[index % dimension] = 1
    return vector
}

private func attributes(_ kind: MediaKind = .image, path: String = "/s/a", modified: TimeInterval = 0) -> FileAttributes {
    FileAttributes(kind: kind, modified: Date(timeIntervalSince1970: modified), path: path)
}

@Suite("FlatVectorIndex")
struct FlatVectorIndexTests {
    @Test(arguments: [true, false])
    func findsNearestAndRespectsFilters(useGPU: Bool) async throws {
        let index = FlatVectorIndex(space: space, initialCapacity: 2, useGPU: useGPU)
        try await index.upsert([
            StoredVector(chunkID: ChunkID(1), fileID: FileID(1), values: unit(0), attributes: attributes(.image)),
            StoredVector(chunkID: ChunkID(2), fileID: FileID(2), values: unit(1), attributes: attributes(.video)),
            StoredVector(chunkID: ChunkID(3), fileID: FileID(3), values: [0.9, 0.1, 0, 0, 0, 0, 0, 0], attributes: attributes(.pdf)),
        ])
        let query = Embedding(normalizing: unit(0), space: space)
        let hits = try await index.search(query, limit: 2, filter: .none)
        #expect(hits.map(\.chunkID) == [ChunkID(1), ChunkID(3)])
        #expect(abs(hits[0].score - 1) < 1e-3)

        let filtered = try await index.search(query, limit: 5, filter: SearchFilter(kinds: [.video]))
        #expect(filtered.map(\.fileID) == [FileID(2)])
    }

    @Test func robustStatisticsDescribeUnrelatedRowsWhenManyRowsMatch() {
        // 40 matches at 0.76 among 160 unrelated rows spread around 0.60.
        let unrelated = (0..<160).map { 0.56 + Float($0 % 9) * 0.01 }
        let (median, deviation) = ScoreStatistics.robust(unrelated + Array(repeating: 0.76, count: 40))
        #expect(abs(median - 0.61) < 0.011)
        // The matches stand out from the median by far more than from the mean (0.63, deviation
        // 0.06, where they sit near z 2.2).
        #expect((0.76 - median) / deviation > 3.25)
    }

    @Test func removeKeepsRemainingRowsConsistent() async throws {
        let index = FlatVectorIndex(space: space, useGPU: false)
        var vectors: [StoredVector] = []
        for chunk in 0..<8 {
            vectors.append(
                StoredVector(
                    chunkID: ChunkID(Int64(chunk)), fileID: FileID(Int64(chunk % 3)), values: unit(chunk), attributes: attributes()))
        }
        try await index.upsert(vectors)
        try await index.remove(fileID: FileID(0))
        #expect(await index.count == 5)
        for chunk in 0..<8 where chunk % 3 != 0 {
            let hit = try await index.search(Embedding(normalizing: unit(chunk), space: space), limit: 1, filter: .none)
            #expect(hit.first?.chunkID == ChunkID(Int64(chunk)))
        }
    }

    @Test func upsertReplacesExistingChunk() async throws {
        let index = FlatVectorIndex(space: space, useGPU: false)
        try await index.upsert([StoredVector(chunkID: ChunkID(1), fileID: FileID(1), values: unit(0), attributes: attributes())])
        try await index.upsert([StoredVector(chunkID: ChunkID(1), fileID: FileID(1), values: unit(4), attributes: attributes())])
        #expect(await index.count == 1)
        let hit = try await index.search(Embedding(normalizing: unit(4), space: space), limit: 1, filter: .none)
        #expect(abs((hit.first?.score ?? 0) - 1) < 1e-3)
    }

    @Test func gpuAndCPUScoresAgree() async throws {
        let dimension = 512
        let big = VectorSpace(modelID: "t", dimension: dimension)
        var generator = SystemRandomNumberGenerator()
        let vectors = (0..<3_000).map { row in
            StoredVector(
                chunkID: ChunkID(Int64(row)), fileID: FileID(Int64(row)),
                values: Embedding(normalizing: (0..<dimension).map { _ in Float.random(in: -1...1, using: &generator) }, space: big).values,
                attributes: attributes()
            )
        }
        let gpu = FlatVectorIndex(space: big, useGPU: true)
        let cpu = FlatVectorIndex(space: big, useGPU: false)
        try await gpu.upsert(vectors)
        try await cpu.upsert(vectors)
        let query = Embedding(normalizing: vectors[42].values, space: big)
        let gpuHits = try await gpu.search(query, limit: 10, filter: .none)
        let cpuHits = try await cpu.search(query, limit: 10, filter: .none)
        #expect(gpuHits.first?.chunkID == ChunkID(42))
        #expect(gpuHits.map(\.chunkID) == cpuHits.map(\.chunkID))
        for (a, b) in zip(gpuHits, cpuHits) { #expect(abs(a.score - b.score) < 1e-3) }
    }

    @Test func wrongDimensionReturnsNothing() async throws {
        let index = FlatVectorIndex(space: space)
        let other = Embedding(normalizing: [1, 0], space: VectorSpace(modelID: "x", dimension: 2))
        #expect(try await index.search(other, limit: 5, filter: .none).isEmpty)
    }
}

@Suite("TopK")
struct TopKTests {
    @Test func keepsHighestScores() {
        var top = TopK<Int>(3)
        for (index, score) in [5, 1, 9, 3, 7, 2].enumerated() { top.insert(index, score: Float(score)) }
        #expect(top.sorted().map(\.score) == [9, 7, 5])
        #expect(top.threshold == 5)
    }
}

@Suite("VectorMatrix")
struct VectorMatrixTests {
    /// Deterministic unit vectors with mixed signs.
    private func vectors(_ count: Int, dimension: Int) -> [[Float]] {
        var state: UInt64 = 42
        return (0..<count).map { _ in
            let raw = (0..<dimension).map { _ -> Float in
                state = state &* 6_364_136_223_846_793_005 &+ 1
                return Float(Int64(bitPattern: state >> 11) % 2_000) / 1_000 - 1
            }
            let norm = sqrt(raw.reduce(0) { $0 + $1 * $1 })
            return raw.map { $0 / norm }
        }
    }

    @Test func roundTripErrorIsSmall() {
        let matrix = VectorMatrix(dimension: 6, device: nil)
        for vector in vectors(20, dimension: 6) {
            let row = matrix.append(vector)
            let restored = matrix.row(row)
            let worst = zip(vector, restored).map { abs($0 - $1) }.max() ?? 0
            // Half a quantization step of the row's largest value.
            #expect(worst <= (vector.map(abs).max() ?? 0) / 254 + 1e-6)
        }
        #expect(matrix.row(matrix.append([0, 0, 0, 0, 0, 0])) == [0, 0, 0, 0, 0, 0])
    }

    @Test(arguments: [6, 512])
    func gpuAndCPUScansAgree(dimension: Int) throws {
        let gpu = try #require(MetalVectorScanner())
        let matrix = VectorMatrix(dimension: dimension, initialCapacity: 2, device: gpu.metalDevice)
        let rows = vectors(300, dimension: dimension)
        for row in rows { _ = matrix.append(row) }
        matrix.removeBySwappingLast(7)
        let query = vectors(1, dimension: dimension)[0]
        let onGPU = gpu.scores(matrix, query: query)
        let onCPU = AccelerateVectorScanner(blockRows: 64).scores(matrix, query: query)
        #expect(onGPU.count == 299)
        #expect(zip(onGPU, onCPU).allSatisfy { abs($0 - $1) < 1e-4 })
        // Close to the exact float dot product.
        let exact = zip(rows[0], query).reduce(0) { $0 + $1.0 * $1.1 }
        #expect(abs(onGPU[0] - exact) < 0.01)
    }
}

@Suite("HybridRanker")
struct HybridRankerTests {
    @Test func fusesAndCollapsesToBestChunkPerFile() {
        let ranker = HybridRanker()
        let semantic = [
            ScoredChunk(chunkID: ChunkID(10), fileID: FileID(1), score: 0.9),
            ScoredChunk(chunkID: ChunkID(11), fileID: FileID(1), score: 0.8),
            ScoredChunk(chunkID: ChunkID(20), fileID: FileID(2), score: 0.7),
        ]
        let keyword = [KeywordHit(fileID: FileID(2), chunkID: ChunkID(20), bm25: -3, attributes: attributes())]
        let ranked = ranker.rank(semantic: semantic, keyword: keyword, names: [], attributes: [:])
        // File 2 matched both ways, so it outranks file 1's single strong semantic match.
        #expect(ranked.map(\.fileID) == [FileID(2), FileID(1)])
        #expect(ranked[1].bestChunk == ChunkID(10))
        #expect(ranked[0].sources == [.semantic, .keyword])
    }

    @Test func dropsWeakSemanticMatches() {
        let ranked = HybridRanker().rank(
            semantic: [ScoredChunk(chunkID: ChunkID(1), fileID: FileID(1), score: 0.05)], keyword: [], names: [], attributes: [:]
        )
        #expect(ranked.isEmpty)
    }

    @Test func dropsSemanticMatchesFarBelowTheBest() {
        var ranker = HybridRanker()
        ranker.minimumSimilarity = 0.6
        ranker.similarityMargin = 0.05
        let semantic = [
            ScoredChunk(chunkID: ChunkID(1), fileID: FileID(1), score: 0.73),
            ScoredChunk(chunkID: ChunkID(2), fileID: FileID(2), score: 0.69),
            ScoredChunk(chunkID: ChunkID(3), fileID: FileID(3), score: 0.63),
        ]
        let keyword = [KeywordHit(fileID: FileID(4), chunkID: ChunkID(4), bm25: -1, attributes: attributes())]
        let ranked = ranker.rank(semantic: semantic, keyword: keyword, names: [], attributes: [:])
        // File 3 clears the absolute cutoff but not the margin; keyword matches are never dropped.
        #expect(Set(ranked.map(\.fileID)) == [FileID(1), FileID(2), FileID(4)])

        ranker.similarityMargin = nil
        #expect(ranker.rank(semantic: semantic, keyword: [], names: [], attributes: [:]).count == 3)
    }

    @Test func calibratesAgainstTheLibraryOnceItIsLargeEnough() {
        var ranker = HybridRanker()
        ranker.minimumSimilarity = 0.6
        ranker.similarityMargin = 0.05
        ranker.minimumZScore = 2.75
        let semantic = [
            ScoredChunk(chunkID: ChunkID(1), fileID: FileID(1), score: 0.73),
            ScoredChunk(chunkID: ChunkID(2), fileID: FileID(2), score: 0.70),
            ScoredChunk(chunkID: ChunkID(3), fileID: FileID(3), score: 0.64),
        ]
        // mean 0.57, deviation 0.03: z = 5.3, 4.3, 2.3, so file 3 falls below 2.75.
        let large = ScoreStatistics(mean: 0.57, deviation: 0.03, count: 500)
        #expect(
            ranker.rank(semantic: semantic, keyword: [], names: [], attributes: [:], statistics: large).map(\.fileID)
                == [FileID(1), FileID(2)])

        // Too few vectors for stable statistics: the margin applies instead.
        let small = ScoreStatistics(mean: 0.57, deviation: 0.03, count: 20)
        #expect(
            Set(ranker.rank(semantic: semantic, keyword: [], names: [], attributes: [:], statistics: small).map(\.fileID))
                == [FileID(1), FileID(2)])
        let tight = [semantic[0], ScoredChunk(chunkID: ChunkID(4), fileID: FileID(4), score: 0.66)]
        // z = 3.0 passes calibration, but on a small library the margin (0.73 - 0.05) drops it.
        #expect(ranker.rank(semantic: tight, keyword: [], names: [], attributes: [:], statistics: large).count == 2)
        #expect(ranker.rank(semantic: tight, keyword: [], names: [], attributes: [:], statistics: small).count == 1)
    }

    @Test func keepsMatchesTooNumerousToStandOutFromTheMean() {
        var ranker = HybridRanker()
        ranker.minimumSimilarity = 0.6
        ranker.minimumZScore = 2.75
        let semantic = [
            ScoredChunk(chunkID: ChunkID(1), fileID: FileID(1), score: 0.76),
            ScoredChunk(chunkID: ChunkID(2), fileID: FileID(2), score: 0.65),
        ]
        // Many matches lift the mean to 0.63 and the deviation to 0.06: z 2.2 for file 1.
        let statistics = ScoreStatistics(mean: 0.63, deviation: 0.06, median: 0.61, robustDeviation: 0.03, count: 500)
        #expect(ranker.rank(semantic: semantic, keyword: [], names: [], attributes: [:], statistics: statistics).isEmpty)

        // Robust z 5.0 for file 1 clears 3.5; file 2 (1.3) still doesn't.
        ranker.minimumRobustZScore = 3.5
        #expect(
            ranker.rank(semantic: semantic, keyword: [], names: [], attributes: [:], statistics: statistics).map(\.fileID)
                == [FileID(1)])
    }

    @Test func partialKeywordMatchesOnlyAddFiles() {
        let ranker = HybridRanker()
        let semantic = [
            ScoredChunk(chunkID: ChunkID(1), fileID: FileID(1), score: 0.9),
            ScoredChunk(chunkID: ChunkID(2), fileID: FileID(2), score: 0.8),
        ]
        let loose = [
            KeywordHit(fileID: FileID(2), chunkID: ChunkID(2), bm25: -5, attributes: attributes()),
            KeywordHit(fileID: FileID(3), chunkID: ChunkID(3), bm25: -4, attributes: attributes()),
        ]
        let ranked = ranker.rank(semantic: semantic, keyword: [], names: [], looseKeyword: loose, attributes: [:])
        // File 2 is not boosted past file 1; file 3, found by nothing else, is added last.
        #expect(ranked.map(\.fileID) == [FileID(1), FileID(2), FileID(3)])
        #expect(ranked[1].sources == .semantic)
    }

    @Test func nameOnlyMatchesHaveNoChunk() {
        let ranked = HybridRanker().rank(
            semantic: [], keyword: [], names: [KeywordHit(fileID: FileID(5), chunkID: nil, bm25: -1, attributes: attributes())],
            attributes: [:]
        )
        #expect(ranked.first?.bestChunk == nil)
        #expect(ranked.first?.sources == .name)
    }

    @Test func recencyBreaksTies() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let hits = [
            KeywordHit(fileID: FileID(1), chunkID: nil, bm25: -1, attributes: attributes(modified: 0)),
            KeywordHit(fileID: FileID(2), chunkID: nil, bm25: -1, attributes: attributes(modified: 99 * 86_400)),
        ]
        var ranker = HybridRanker()
        ranker.nameWeight = 1
        // Same RRF contribution at ranks 1 and 2 would favour file 1; give them equal ranks via two lists.
        let ranked =
            ranker.rank(
                semantic: [], keyword: [], names: [hits[0]], attributes: [FileID(1): hits[0].attributes, FileID(2): hits[1].attributes],
                now: now
            ) + ranker.rank(semantic: [], keyword: [], names: [hits[1]], attributes: [FileID(2): hits[1].attributes], now: now)
        #expect(ranked[1].score > ranked[0].score)
    }

    @Test func scoreFusionWeighsHowStrongAMatchIs() {
        var ranker = HybridRanker()
        ranker.fusion = .reciprocalRank
        ranker.minimumSimilarity = 0.3
        let semantic = [
            ScoredChunk(chunkID: ChunkID(1), fileID: FileID(1), score: 0.80),
            ScoredChunk(chunkID: ChunkID(2), fileID: FileID(2), score: 0.78),
        ]
        // Almost the same meaning, but file 2's keyword match is ten times as strong.
        let keyword = [
            KeywordHit(fileID: FileID(2), chunkID: ChunkID(2), bm25: -10, attributes: attributes()),
            KeywordHit(fileID: FileID(1), chunkID: ChunkID(1), bm25: -1, attributes: attributes()),
        ]
        // By rank alone each file wins one list: a tie, broken by file ID.
        #expect(ranker.rank(semantic: semantic, keyword: keyword, names: [], attributes: [:]).map(\.fileID) == [FileID(1), FileID(2)])

        ranker.fusion = .scores
        let ranked = ranker.rank(semantic: semantic, keyword: keyword, names: [], attributes: [:])
        #expect(ranked.map(\.fileID) == [FileID(2), FileID(1)])
        // Cosine scales from the 0.3 floor to the best hit, BM25 against the best hit.
        #expect(abs(ranked[0].score - (0.48 / 0.5 + 1)) < 0.001)
        #expect(abs(ranked[1].score - (1 + 0.1)) < 0.001)
    }

    @Test func perFileFusionCountsMatchesOnDifferentPages() {
        let semantic = [
            ScoredChunk(chunkID: ChunkID(10), fileID: FileID(1), score: 0.9),
            ScoredChunk(chunkID: ChunkID(11), fileID: FileID(1), score: 0.89),
            ScoredChunk(chunkID: ChunkID(20), fileID: FileID(2), score: 0.85),
            ScoredChunk(chunkID: ChunkID(30), fileID: FileID(3), score: 0.8),
        ]
        // File 3 matches the words on another page than the one that matched the meaning.
        let keyword = [KeywordHit(fileID: FileID(3), chunkID: ChunkID(31), bm25: -3, attributes: attributes())]
        var ranker = HybridRanker()
        ranker.fusion = .reciprocalRank
        let perChunk = ranker.rank(semantic: semantic, keyword: keyword, names: [], attributes: [:])
        #expect(perChunk.first?.fileID == FileID(1))

        ranker.fusesPerFile = true
        let ranked = ranker.rank(semantic: semantic, keyword: keyword, names: [], attributes: [:])
        #expect(ranked.map(\.fileID) == [FileID(3), FileID(1), FileID(2)])
        #expect(ranked[0].sources == [.semantic, .keyword])
        #expect(ranked[0].similarity == 0.8)
        // File 1's second chunk shares its rank, so file 2 ranks second in the semantic list.
        #expect(abs(ranked[2].score - 1 / 62) < 1e-9)
    }
}

@Suite("QueryStyle")
struct QueryStyleTests {
    @Test(arguments: ["IMG_4821", "invoice 2024-0413", "report.pdf", "\"exact phrase\"", "iPhone backup", "v2 slides"])
    func literal(_ text: String) {
        #expect(QueryStyle(text) == .literal)
    }

    @Test(arguments: ["apple", "baseball bat", "flight confirmation", "the receipt from Goa"])
    func balanced(_ text: String) {
        #expect(QueryStyle(text) == .balanced)
    }

    @Test(arguments: [
        "that photo of my dog at the lake", "5% of perinatal mortality is due to low birth weight.",
    ])
    func descriptive(_ text: String) {
        #expect(QueryStyle(text) == .descriptive)
    }

    @Test func fullStopIsNotAFileName() {
        #expect(!QueryStyle.looksLikeIdentifier("weight."))
        #expect(QueryStyle.looksLikeIdentifier("notes.md"))
    }
}

@Suite("Snippet")
struct SnippetTests {
    @Test func centersOnFirstTermAndHighlights() {
        let text =
            String(repeating: "filler words here ", count: 20) + "the Pricing chart for Acme " + String(repeating: "tail ", count: 40)
        let snippet = Snippet.make(from: text, terms: ["pricing", "acme"], maxLength: 120)
        #expect(snippet.text.hasPrefix("…"))
        #expect(snippet.text.hasSuffix("…"))
        #expect(snippet.highlights.count == 2)
        #expect(snippet.text[snippet.highlights[0]] == "Pricing")
    }

    @Test func diacriticInsensitiveHighlight() {
        let snippet = Snippet.make(from: "Lunch at Café Zürich", terms: ["cafe"])
        #expect(snippet.highlights.count == 1)
        #expect(snippet.text[snippet.highlights[0]] == "Café")
    }

    @Test func emptyTextGivesEmptySnippet() {
        #expect(Snippet.make(from: "  \n ", terms: ["a"]).text.isEmpty)
    }
}

@Suite("QueryParser")
struct QueryParserTests {
    @Test func extractsTokens() {
        let parsed = QueryParser.parse("beach kind:videos in:Downloads date:week sunset")
        #expect(parsed.text == "beach sunset")
        #expect(parsed.tokens == [.kind(.video), .folder("Downloads"), .modifiedSince(.week)])
    }

    @Test func freeTierOnlyAppliesKindFilters() {
        let parsed = QueryParser.parse("x kind:pdf in:Downloads date:today")
        let free = parsed.filter(allowFullFilters: false, sources: ["/Users/a/Downloads"])
        #expect(free.kinds == [.pdf])
        #expect(free.folders.isEmpty)
        #expect(free.modifiedAfter == nil)
        let pro = parsed.filter(allowFullFilters: true, sources: ["/Users/a/Downloads"])
        #expect(pro.folders == ["/Users/a/Downloads"])
        #expect(pro.modifiedAfter != nil)
    }

    @Test func unknownTokensStayInText() {
        let parsed = QueryParser.parse("time 10:30 kind:spaceship")
        #expect(parsed.text == "time 10:30 kind:spaceship")
        #expect(parsed.tokens.isEmpty)
    }
}

@Suite("ResultStabilizer")
struct ResultStabilizerTests {
    @Test func keepsPinnedRowInPlace() {
        let result = ResultStabilizer.stabilize(previous: ["a", "b", "c"], next: ["x", "y", "b", "a", "c"], pinned: "b")
        #expect(result == ["x", "b", "y", "a", "c"])
    }

    @Test func noPinOrMissingPinPassesThrough() {
        #expect(ResultStabilizer.stabilize(previous: ["a"], next: ["b", "a"], pinned: nil) == ["b", "a"])
        #expect(ResultStabilizer.stabilize(previous: ["a"], next: ["b"], pinned: "a") == ["b"])
    }
}

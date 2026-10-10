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

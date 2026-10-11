import Foundation
import GlintCore
import GlintStore

/// How a file matched a query.
public struct MatchSources: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let semantic = MatchSources(rawValue: 1 << 0)
    public static let keyword = MatchSources(rawValue: 1 << 1)
    public static let name = MatchSources(rawValue: 1 << 2)
}

/// A file-level ranking result before hydration.
public struct RankedFile: Sendable, Hashable {
    public var fileID: FileID
    /// The chunk that best explains the match (`nil` for a name-only match).
    public var bestChunk: ChunkID?
    public var score: Double
    public var sources: MatchSources
    /// Cosine similarity of the best semantic chunk, if any.
    public var similarity: Float?
}

/// Fuses semantic and keyword results, collapses to the best chunk per file, applies a small
/// recency boost, and sorts.
public struct HybridRanker: Sendable {
    /// How a list's hits turn into scores before they are added up.
    public enum Fusion: Sendable, Hashable {
        /// Reciprocal rank fusion: a hit counts by its position in its list only.
        case reciprocalRank
        /// A hit counts by its own score, scaled to 0...1 within its list: cosine between the
        /// semantic floor and the best hit, BM25 against the best hit. A near-exact match and a
        /// marginal one no longer count the same just because they sit at the same rank.
        case scores
    }

    /// Scores beat ranks on every eval: SciFact MRR 0.798 -> 0.811, literal look-ups ("Fbxo15",
    /// "CD21 fibroblasts") Recall@10 0.925 -> 0.975; photos unchanged.
    public var fusion: Fusion = .scores
    /// Fuse per file: each list contributes the best chunk it found in a file, and files (not
    /// chunks) are ranked within each list. A PDF matching the words on one page and the
    /// meaning on another counts both, and one file's many chunks don't push other files down.
    public var fusesPerFile = false
    /// RRF constant; 60 is the standard value from the original paper.
    public var k: Double = 60
    public var semanticWeight: Double = 1
    public var keywordWeight: Double = 1
    public var nameWeight: Double = 1.2
    /// Weight of keyword and name matches that contain only some of the query's words. They
    /// only add files nothing else found, and rank low: boosting files already found reorders
    /// them by weak evidence (SciFact MRR 0.80 -> 0.73).
    public var looseKeywordWeight: Double = 0.25
    /// Semantic hits below this cosine similarity are dropped as noise.
    public var minimumSimilarity: Float = 0.25
    /// Semantic hits more than this below the best hit are dropped too (`nil`: off).
    public var similarityMargin: Float?
    /// Semantic hits fewer than this many standard deviations above the query's mean score
    /// over the library are dropped (`nil`: off). Needs the statistics passed to `rank`, and
    /// replaces `similarityMargin` once the library has `calibrationMinimumRows` vectors.
    public var minimumZScore: Float?
    /// Semantic hits this many robust deviations above the query's median score are kept even
    /// below `minimumZScore` (`nil`: off). Catches matches too numerous to stand out from the
    /// mean, such as a folder full of train photos for "train".
    public var minimumRobustZScore: Float?
    /// Below this many vectors the library's score statistics are too noisy to calibrate with.
    public var calibrationMinimumRows = 200
    /// Maximum relative boost for a file modified today, decaying with `recencyHalfLife`.
    public var recencyBoost: Double = 0.05
    public var recencyHalfLife: TimeInterval = 90 * 24 * 3_600

    public init() {}

    public func rank(
        semantic: [ScoredChunk],
        keyword: [KeywordHit],
        names: [KeywordHit],
        looseKeyword: [KeywordHit] = [],
        looseNames: [KeywordHit] = [],
        attributes: [FileID: FileAttributes],
        statistics: ScoreStatistics? = nil,
        now: Date = Date()
    ) -> [RankedFile] {
        let floor = semanticFloor(semantic, statistics: statistics)
        var files = chunkMatches(semantic: semantic.filter { $0.score >= floor }, keyword: keyword, floor: floor)
        for (hit, score) in zip(names, contributions(names.map { ($0.fileID, -$0.bm25) }, weight: nameWeight)) {
            files[hit.fileID, default: .empty(hit.fileID)].score += score
            files[hit.fileID]?.sources.insert(.name)
        }
        files.merge(looseFiles(keyword: looseKeyword, names: looseNames, excluding: files)) { current, _ in current }

        let ranked = files.values.map { file -> RankedFile in
            var file = file
            if let modified = attributes[file.fileID]?.modified {
                let age = max(0, now.timeIntervalSince(modified))
                file.score *= 1 + recencyBoost * pow(0.5, age / recencyHalfLife)
            }
            return file
        }
        return ranked.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.fileID < rhs.fileID
        }
    }

    /// Files matched through their chunks, scored by their best chunk or, with `fusesPerFile`,
    /// by each list's best chunk in them.
    private func chunkMatches(semantic: [ScoredChunk], keyword: [KeywordHit], floor: Float) -> [FileID: RankedFile] {
        var chunkScores: [ChunkID: (file: FileID, score: Double)] = [:]
        var similarity: [ChunkID: Float] = [:]
        var files: [FileID: RankedFile] = [:]
        // Each list's best contribution per file, and the best cosine per file.
        var listBest: [[FileID: Double]] = [[:], [:]]
        var bestSimilarity: [FileID: Float] = [:]

        let semanticScores = contributions(
            semantic.map { ($0.fileID, Double($0.score)) }, weight: semanticWeight, lowerBound: Double(floor))
        for (hit, score) in zip(semantic, semanticScores) {
            chunkScores[hit.chunkID, default: (hit.fileID, 0)].score += score
            similarity[hit.chunkID] = hit.score
            listBest[0][hit.fileID] = max(listBest[0][hit.fileID] ?? 0, score)
            bestSimilarity[hit.fileID] = max(bestSimilarity[hit.fileID] ?? hit.score, hit.score)
            files[hit.fileID, default: .empty(hit.fileID)].sources.insert(.semantic)
        }
        let chunkKeyword = keyword.filter { $0.chunkID != nil }
        let keywordScores = contributions(chunkKeyword.map { ($0.fileID, -$0.bm25) }, weight: keywordWeight)
        for (hit, score) in zip(chunkKeyword, keywordScores) {
            guard let chunkID = hit.chunkID else { continue }
            chunkScores[chunkID, default: (hit.fileID, 0)].score += score
            listBest[1][hit.fileID] = max(listBest[1][hit.fileID] ?? 0, score)
            files[hit.fileID, default: .empty(hit.fileID)].sources.insert(.keyword)
        }
        // Best chunk per file.
        for (chunkID, entry) in chunkScores {
            var file = files[entry.file, default: .empty(entry.file)]
            if file.bestChunk == nil || entry.score > file.score {
                file.bestChunk = chunkID
                file.score = entry.score
                file.similarity = similarity[chunkID]
            }
            files[entry.file] = file
        }
        if fusesPerFile {
            for (id, file) in files {
                files[id]?.score = (listBest[0][id] ?? 0) + (listBest[1][id] ?? 0)
                files[id]?.similarity = file.similarity ?? bestSimilarity[id]
            }
        }
        return files
    }

    /// Partial matches only add files nothing else found.
    private func looseFiles(keyword: [KeywordHit], names: [KeywordHit], excluding files: [FileID: RankedFile]) -> [FileID: RankedFile] {
        var loose: [FileID: RankedFile] = [:]
        let chunkKeyword = keyword.filter { $0.chunkID != nil }
        let keywordScores = contributions(chunkKeyword.map { ($0.fileID, -$0.bm25) }, weight: keywordWeight * looseKeywordWeight)
        for (hit, score) in zip(chunkKeyword, keywordScores) where files[hit.fileID] == nil {
            guard let chunkID = hit.chunkID else { continue }
            var file = loose[hit.fileID, default: .empty(hit.fileID)]
            if score > file.score {
                file.bestChunk = chunkID
                file.score = score
            }
            file.sources.insert(.keyword)
            loose[hit.fileID] = file
        }
        let nameScores = contributions(names.map { ($0.fileID, -$0.bm25) }, weight: nameWeight * looseKeywordWeight)
        for (hit, score) in zip(names, nameScores) where files[hit.fileID] == nil {
            loose[hit.fileID, default: .empty(hit.fileID)].score += score
            loose[hit.fileID]?.sources.insert(.name)
        }
        return loose
    }

    /// What each hit of one list (best first, higher `raw` is better) adds to its chunk or file.
    /// `lowerBound` is the raw score that would count for nothing.
    private func contributions(_ hits: [(file: FileID, raw: Double)], weight: Double, lowerBound: Double = 0) -> [Double] {
        switch fusion {
        case .reciprocalRank:
            guard fusesPerFile else { return hits.indices.map { weight / (k + Double($0 + 1)) } }
            // Rank files, not chunks: a file's later chunks share its rank.
            var fileRanks: [FileID: Int] = [:]
            return hits.map { hit in
                let rank = fileRanks[hit.file] ?? fileRanks.count
                fileRanks[hit.file] = rank
                return weight / (k + Double(rank + 1))
            }
        case .scores:
            guard let best = hits.map(\.raw).max() else { return [] }
            let range = best - lowerBound
            return hits.map { range > 0 ? weight * max(0, $0.raw - lowerBound) / range : weight }
        }
    }

    /// The lowest semantic score kept: calibrated against the library's score statistics when
    /// there are enough vectors, otherwise a margin below the best match.
    private func semanticFloor(_ semantic: [ScoredChunk], statistics: ScoreStatistics?) -> Float {
        var floor = minimumSimilarity
        if let minimumZScore, let statistics, statistics.deviation > 0, statistics.count >= calibrationMinimumRows {
            var calibrated = statistics.mean + minimumZScore * statistics.deviation
            if let minimumRobustZScore, statistics.robustDeviation > 0 {
                calibrated = min(calibrated, statistics.median + minimumRobustZScore * statistics.robustDeviation)
            }
            floor = max(floor, calibrated)
        } else if let similarityMargin, let best = semantic.map(\.score).max() {
            floor = max(floor, best - similarityMargin)
        }
        return floor
    }
}

extension RankedFile {
    static func empty(_ id: FileID) -> RankedFile {
        RankedFile(fileID: id, bestChunk: nil, score: 0, sources: [], similarity: nil)
    }
}

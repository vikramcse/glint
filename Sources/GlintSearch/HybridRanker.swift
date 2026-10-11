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

/// Fuses semantic and keyword results with reciprocal rank fusion, collapses to the best
/// chunk per file, applies a small recency boost, and sorts.
public struct HybridRanker: Sendable {
    /// RRF constant; 60 is the standard value from the original paper.
    public var k: Double = 60
    public var semanticWeight: Double = 1
    public var keywordWeight: Double = 1
    public var nameWeight: Double = 1.2
    /// Semantic hits below this cosine similarity are dropped as noise.
    public var minimumSimilarity: Float = 0.25
    /// Semantic hits more than this below the best hit are dropped too (`nil`: off).
    public var similarityMargin: Float?
    /// Semantic hits fewer than this many standard deviations above the query's mean score
    /// over the library are dropped (`nil`: off). Needs the statistics passed to `rank`, and
    /// replaces `similarityMargin` once the library has `calibrationMinimumRows` vectors.
    public var minimumZScore: Float?
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
        attributes: [FileID: FileAttributes],
        statistics: ScoreStatistics? = nil,
        now: Date = Date()
    ) -> [RankedFile] {
        var chunkScores: [ChunkID: (file: FileID, score: Double)] = [:]
        var similarity: [ChunkID: Float] = [:]
        var files: [FileID: RankedFile] = [:]

        let floor = semanticFloor(semantic, statistics: statistics)
        for (rank, hit) in semantic.filter({ $0.score >= floor }).enumerated() {
            chunkScores[hit.chunkID, default: (hit.fileID, 0)].score += semanticWeight / (k + Double(rank + 1))
            similarity[hit.chunkID] = hit.score
            files[hit.fileID, default: .empty(hit.fileID)].sources.insert(.semantic)
        }
        for (rank, hit) in keyword.enumerated() {
            guard let chunkID = hit.chunkID else { continue }
            chunkScores[chunkID, default: (hit.fileID, 0)].score += keywordWeight / (k + Double(rank + 1))
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
        for (rank, hit) in names.enumerated() {
            files[hit.fileID, default: .empty(hit.fileID)].score += nameWeight / (k + Double(rank + 1))
            files[hit.fileID]?.sources.insert(.name)
        }

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

    /// The lowest semantic score kept: calibrated against the library's score statistics when
    /// there are enough vectors, otherwise a margin below the best match.
    private func semanticFloor(_ semantic: [ScoredChunk], statistics: ScoreStatistics?) -> Float {
        var floor = minimumSimilarity
        if let minimumZScore, let statistics, statistics.deviation > 0, statistics.count >= calibrationMinimumRows {
            floor = max(floor, statistics.mean + minimumZScore * statistics.deviation)
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

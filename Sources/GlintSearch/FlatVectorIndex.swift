import Accelerate
import Foundation
import GlintCore
import Metal

/// Exact nearest-neighbour search over one contiguous, GPU-resident matrix of unit vectors.
/// A query is a single matrix-vector multiply followed by a bounded top-k selection.
///
/// Rows are removed by swapping in the last row, so the matrix never has holes.
public actor FlatVectorIndex: VectorIndex {
    public let space: VectorSpace
    private let matrix: VectorMatrix
    private let scanner: any VectorScanner
    private var chunkIDs: [ChunkID] = []
    private var fileIDs: [FileID] = []
    private var rowOfChunk: [ChunkID: Int] = [:]
    private var rowsOfFile: [FileID: Set<Int>] = [:]
    private var attributes: [FileID: FileAttributes] = [:]
    /// Bumped on every change. The indexer updates this index each time it commits, removes or
    /// moves a file, so it also tells the search engine when cached keyword hits may be stale.
    public private(set) var generation = 0

    /// - Parameter useGPU: scan with Metal when available (tests force the CPU path to compare).
    public init(space: VectorSpace, initialCapacity: Int = 4_096, useGPU: Bool = true) {
        self.space = space
        let metal = useGPU ? MetalVectorScanner() : nil
        scanner = metal ?? AccelerateVectorScanner()
        matrix = VectorMatrix(dimension: space.dimension, initialCapacity: initialCapacity, device: metal?.metalDevice)
    }

    public var count: Int { matrix.rows }

    /// Approximate resident memory of the matrix, for Settings > Models.
    public var residentBytes: Int { matrix.byteCount }

    public func upsert(_ vectors: [StoredVector]) async throws {
        generation += 1
        for vector in vectors {
            guard vector.values.count == space.dimension else { continue }
            attributes[vector.fileID] = vector.attributes
            if let row = rowOfChunk[vector.chunkID] {
                matrix.write(vector.values, at: row)
                continue
            }
            let row = matrix.append(vector.values)
            chunkIDs.append(vector.chunkID)
            fileIDs.append(vector.fileID)
            rowOfChunk[vector.chunkID] = row
            rowsOfFile[vector.fileID, default: []].insert(row)
        }
    }

    public func remove(fileID: FileID) async throws {
        generation += 1
        guard let rows = rowsOfFile[fileID] else { return }
        // Remove from the highest row down so swapped-in rows are never ones we still need to remove.
        for row in rows.sorted(by: >) { removeRow(row) }
        rowsOfFile[fileID] = nil
        attributes[fileID] = nil
    }

    public func removeAll() {
        generation += 1
        matrix.removeAll()
        chunkIDs.removeAll()
        fileIDs.removeAll()
        rowOfChunk.removeAll()
        rowsOfFile.removeAll()
        attributes.removeAll()
    }

    /// Updates the cached attributes of a file (for example after a rename).
    public func updateAttributes(_ value: FileAttributes, for fileID: FileID) {
        generation += 1
        if attributes[fileID] != nil { attributes[fileID] = value }
    }

    public func search(_ query: Embedding, limit: Int, filter: SearchFilter) async throws -> [ScoredChunk] {
        try await searchWithStatistics(query, limit: limit, filter: filter).hits
    }

    /// Like `search`, plus the centre and spread of the query's score over every stored row,
    /// which tells how far a hit stands out from the library as a whole.
    public func searchWithStatistics(
        _ query: Embedding, limit: Int, filter: SearchFilter
    ) async throws -> (hits: [ScoredChunk], statistics: ScoreStatistics?) {
        guard query.dimension == space.dimension, matrix.rows > 0, limit > 0 else { return ([], nil) }
        let state = Signposts.search.beginInterval(Signposts.Name.vectorScan)
        defer { Signposts.search.endInterval(Signposts.Name.vectorScan, state) }

        let scores = scanner.scores(matrix, query: query.values)
        var mean: Float = 0
        var deviation: Float = 0
        vDSP_normalize(scores, 1, nil, 1, &mean, &deviation, vDSP_Length(scores.count))
        let allowed = allowedFiles(for: filter)
        var top = TopK<Int>(limit)
        for row in 0..<scores.count {
            let score = scores[row]
            guard score > top.threshold else { continue }
            if let allowed, !allowed.contains(fileIDs[row]) { continue }
            top.insert(row, score: score)
        }
        let hits = top.sorted().map { ScoredChunk(chunkID: chunkIDs[$0.element], fileID: fileIDs[$0.element], score: $0.score) }
        let (median, robustDeviation) = ScoreStatistics.robust(scores)
        return (
            hits,
            ScoreStatistics(
                mean: mean, deviation: deviation, median: median, robustDeviation: robustDeviation, count: scores.count)
        )
    }

    /// The kind of each of these files that has vectors here.
    public func kinds(of files: some Sequence<FileID>) -> [FileID: MediaKind] {
        var kinds: [FileID: MediaKind] = [:]
        for file in files { kinds[file] = attributes[file]?.kind }
        return kinds
    }

    /// The vectors stored for one file (used by "find similar").
    public func vectors(of fileID: FileID) -> [[Float]] {
        (rowsOfFile[fileID] ?? []).sorted().map(matrix.row)
    }

    private func allowedFiles(for filter: SearchFilter) -> Set<FileID>? {
        guard !filter.isEmpty else { return nil }
        return Set(attributes.lazy.filter { filter.matches(fileID: $0.key, attributes: $0.value) }.map(\.key))
    }

    private func removeRow(_ row: Int) {
        let last = matrix.rows - 1
        let removedChunk = chunkIDs[row]
        let removedFile = fileIDs[row]
        rowOfChunk[removedChunk] = nil
        rowsOfFile[removedFile]?.remove(row)
        if row != last {
            let movedChunk = chunkIDs[last]
            let movedFile = fileIDs[last]
            chunkIDs[row] = movedChunk
            fileIDs[row] = movedFile
            rowOfChunk[movedChunk] = row
            rowsOfFile[movedFile]?.remove(last)
            rowsOfFile[movedFile]?.insert(row)
        }
        matrix.removeBySwappingLast(row)
        chunkIDs.removeLast()
        fileIDs.removeLast()
    }
}

/// Distribution of one query's similarity over the whole library.
public struct ScoreStatistics: Sendable, Hashable {
    public var mean: Float
    public var deviation: Float
    /// Median and scaled median absolute deviation (in standard deviations of a normal
    /// distribution). Unlike the mean and deviation they describe the unrelated rows even when
    /// many rows match: a folder of 40 train photos lifted the mean and deviation so far that
    /// "train" scored no photo above z 2.4.
    public var median: Float
    public var robustDeviation: Float
    /// Rows the statistics were computed over.
    public var count: Int

    public init(mean: Float, deviation: Float, median: Float? = nil, robustDeviation: Float? = nil, count: Int) {
        self.mean = mean
        self.deviation = deviation
        self.median = median ?? mean
        self.robustDeviation = robustDeviation ?? deviation
        self.count = count
    }

    /// The median and scaled median absolute deviation of `scores`.
    public static func robust(_ scores: [Float]) -> (median: Float, deviation: Float) {
        let median = median(scores)
        return (median, 1.4826 * Self.median(scores.map { abs($0 - median) }))
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var sorted = values
        vDSP_vsort(&sorted, vDSP_Length(sorted.count), 1)
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

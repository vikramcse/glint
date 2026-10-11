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
        guard let rows = rowsOfFile[fileID] else { return }
        // Remove from the highest row down so swapped-in rows are never ones we still need to remove.
        for row in rows.sorted(by: >) { removeRow(row) }
        rowsOfFile[fileID] = nil
        attributes[fileID] = nil
    }

    public func removeAll() {
        matrix.removeAll()
        chunkIDs.removeAll()
        fileIDs.removeAll()
        rowOfChunk.removeAll()
        rowsOfFile.removeAll()
        attributes.removeAll()
    }

    /// Updates the cached attributes of a file (for example after a rename).
    public func updateAttributes(_ value: FileAttributes, for fileID: FileID) {
        if attributes[fileID] != nil { attributes[fileID] = value }
    }

    public func search(_ query: Embedding, limit: Int, filter: SearchFilter) async throws -> [ScoredChunk] {
        try await searchWithStatistics(query, limit: limit, filter: filter).hits
    }

    /// Like `search`, plus the mean and spread of the query's score over every stored row,
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
        return (hits, ScoreStatistics(mean: mean, deviation: deviation, count: scores.count))
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
    /// Rows the statistics were computed over.
    public var count: Int

    public init(mean: Float, deviation: Float, count: Int) {
        self.mean = mean
        self.deviation = deviation
        self.count = count
    }
}

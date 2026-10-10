import Foundation
import GlintCore

/// Pipeline stages timed per file.
public enum IndexingStage: String, Sendable, CaseIterable, Codable {
    case hash, extract, embed, commit
}

/// Accumulates where indexing time goes, per media kind and stage. Used by the benchmark and
/// the throughput regression guard; costs a few actor hops per file when enabled.
public actor IndexingStats {
    public struct KindStats: Sendable, Codable {
        public var files = 0
        public var bytes: Int64 = 0
        public var chunks = 0
        public var vectors = 0
        /// Seconds spent per stage, summed across concurrent workers.
        public var stageSeconds: [IndexingStage: Double] = [:]
    }

    public private(set) var kinds: [MediaKind: KindStats] = [:]

    public init() {}

    func record(_ kind: MediaKind, stage: IndexingStage, seconds: Double) {
        kinds[kind, default: KindStats()].stageSeconds[stage, default: 0] += seconds
    }

    func finish(_ kind: MediaKind, bytes: Int64, chunks: Int, vectors: Int) {
        kinds[kind, default: KindStats()].files += 1
        kinds[kind, default: KindStats()].bytes += bytes
        kinds[kind, default: KindStats()].chunks += chunks
        kinds[kind, default: KindStats()].vectors += vectors
    }

    public func reset() { kinds = [:] }
}

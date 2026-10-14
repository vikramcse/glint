import Foundation
import os

/// Loggers and signposters shared by every module. Paths and queries must be logged with
/// `privacy: .private`; counts and timings may be public.
public enum Log {
    public static let subsystem = "app.glint.mac"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let indexer = Logger(subsystem: subsystem, category: "indexer")
    public static let extractor = Logger(subsystem: subsystem, category: "extractor")
    public static let embedding = Logger(subsystem: subsystem, category: "embedding")
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let search = Logger(subsystem: subsystem, category: "search")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}

/// Signposts for every budgeted search and indexing path.
public enum Signposts {
    public static let search = OSSignposter(subsystem: Log.subsystem, category: .pointsOfInterest)
    public static let indexing = OSSignposter(subsystem: Log.subsystem, category: "indexing")

    /// Names used in Instruments and the performance suite.
    public enum Name {
        public static let keywordSearch: StaticString = "KeywordSearch"
        public static let queryEmbedding: StaticString = "QueryEmbedding"
        public static let vectorScan: StaticString = "VectorScan"
        public static let mergedResults: StaticString = "MergedResults"
        public static let panelShow: StaticString = "PanelShow"
        public static let openResult: StaticString = "OpenResult"
        public static let extractFile: StaticString = "ExtractFile"
        public static let embedBatch: StaticString = "EmbedBatch"
        public static let commitFile: StaticString = "CommitFile"
    }
}

/// Monotonic clock helper for budgets measured in tests and the eval harness.
public struct Stopwatch: Sendable {
    private let start = ContinuousClock.now
    public init() {}
    public var elapsed: Duration { ContinuousClock.now - start }
    public var milliseconds: Double {
        let components = elapsed.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}

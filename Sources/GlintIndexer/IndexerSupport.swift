import CryptoKit
import Foundation
import GlintCore

/// Errors the indexer reports to the UI.
public enum IndexerError: GlintError, Equatable {
    case sourceUnreadable
    case unsupportedFile

    public var category: ErrorCategory {
        switch self {
        case .sourceUnreadable: .permissionDenied
        case .unsupportedFile: .unsupported
        }
    }

    public var description: String {
        switch self {
        case .sourceUnreadable: "Glint cannot read this folder"
        case .unsupportedFile: "This file type is not supported"
        }
    }
}

/// Tunables for the indexing pipeline.
public struct IndexerOptions: Sendable, Hashable {
    /// Files in flight at once: each worker hashes, decodes and extracts one file (CPU stage).
    public var concurrentFiles: Int
    /// Maximum inputs per embedding call when the user is not typing; windows from several
    /// files are packed together up to this size.
    public var embeddingBatchSize: Int
    /// How long the embedding lane waits for other files to fill a batch.
    public var embeddingBatchWait: Duration
    /// Embedding calls in flight at once. One keeps a batched GPU model's batches full;
    /// providers that work input by input (the built-in model) gain from a few.
    public var embeddingLanes: Int
    /// Embedding windows one file may have in flight while it keeps extracting; bounds memory
    /// for long videos and PDFs.
    public var embeddingWindowsInFlight: Int
    /// Most files committed in one group transaction.
    public var commitBatchSize: Int
    /// Concurrent Vision text recognitions (the Neural Engine saturates at about two).
    public var ocrLaneWidth: Int
    /// Fraction of `concurrentFiles` and OCR lanes used on battery or when the Mac is warm.
    public var constrainedWidthFactor: Double
    /// Chunks kept per file; protects the index from pathological files.
    public var maxChunksPerFile: Int
    /// Index video only on AC power.
    public var videoOnlyOnPower: Bool
    /// Fuse a video's transcript into its clip input. Images decide this themselves
    /// (`ImageExtractor`): screenshots fuse their OCR text, camera photos don't.
    public var fuseTextIntoMedia: Bool
    /// Embed text chunks with their file's name as the document title.
    public var documentTitles: Bool
    /// How long to wait between watcher events before applying them.
    public var watcherLatency: TimeInterval
    /// How often sources on network shares are rescanned. FSEvents misses changes made on
    /// other machines, and offline sources are checked for their return on the same timer.
    public var networkRescanInterval: Duration
    /// Remote files larger than this are not downloaded to be indexed; they are marked failed.
    public var maxRemoteFileSize: Int64

    public init(
        concurrentFiles: Int = max(2, ProcessInfo.processInfo.activeProcessorCount),
        embeddingBatchSize: Int = 32,
        embeddingBatchWait: Duration = .milliseconds(4),
        embeddingLanes: Int = 2,
        embeddingWindowsInFlight: Int = 2,
        commitBatchSize: Int = 64,
        ocrLaneWidth: Int = 2,
        constrainedWidthFactor: Double = 0.5,
        maxChunksPerFile: Int = 4_000,
        videoOnlyOnPower: Bool = false,
        fuseTextIntoMedia: Bool = true,
        documentTitles: Bool = false,
        watcherLatency: TimeInterval = 1,
        networkRescanInterval: Duration = .seconds(15 * 60),
        maxRemoteFileSize: Int64 = 4 * 1_024 * 1_024 * 1_024
    ) {
        self.concurrentFiles = concurrentFiles
        self.embeddingBatchSize = embeddingBatchSize
        self.embeddingBatchWait = embeddingBatchWait
        self.embeddingLanes = embeddingLanes
        self.embeddingWindowsInFlight = embeddingWindowsInFlight
        self.commitBatchSize = commitBatchSize
        self.ocrLaneWidth = ocrLaneWidth
        self.constrainedWidthFactor = constrainedWidthFactor
        self.maxChunksPerFile = maxChunksPerFile
        self.videoOnlyOnPower = videoOnlyOnPower
        self.fuseTextIntoMedia = fuseTextIntoMedia
        self.documentTitles = documentTitles
        self.watcherLatency = watcherLatency
        self.networkRescanInterval = networkRescanInterval
        self.maxRemoteFileSize = maxRemoteFileSize
    }

    /// Workers to run given the power state.
    func workers(constrained: Bool) -> Int {
        constrained ? max(1, Int((Double(concurrentFiles) * constrainedWidthFactor).rounded())) : max(1, concurrentFiles)
    }

    /// OCR lanes to allow given the power state.
    func ocrLanes(constrained: Bool) -> Int {
        constrained ? max(1, Int((Double(ocrLaneWidth) * constrainedWidthFactor).rounded(.down))) : max(1, ocrLaneWidth)
    }
}

/// Content fingerprints that map copies, moves and touched-but-unchanged files to vectors
/// already stored. Small files are hashed fully; large media is sampled (size plus the
/// first, middle and last megabyte), which is enough to tell real edits apart.
public enum ContentHasher {
    public static let fullHashLimit: Int64 = 64 * 1_024 * 1_024
    static let sampleSize = 1_024 * 1_024

    public static func hash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int64(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }

        if size <= fullHashLimit {
            while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
            }
            return "f" + hex(hasher.finalize())
        }
        for offset in [Int64(0), size / 2, size - Int64(sampleSize)] {
            try handle.seek(toOffset: UInt64(offset))
            if let data = try handle.read(upToCount: sampleSize) { hasher.update(data: data) }
        }
        return "s" + hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Decides when indexing should pause, or slow down, to protect battery and thermals.
public protocol PowerMonitoring: Sendable {
    func pauseReason() -> PauseReason?
    var isOnBattery: Bool { get }
    /// On battery or warm: run narrower lanes instead of pausing.
    var isConstrained: Bool { get }
}

extension PowerMonitoring {
    public var isConstrained: Bool { isOnBattery }
}

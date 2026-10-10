import CryptoKit
import Foundation
import GlintCore

/// Errors the indexer reports to the UI.
public enum IndexerError: GlintError, Equatable {
    case sourceLimitReached(limit: Int)
    case externalDrivesRequirePro
    case sourceUnreadable
    case unsupportedFile

    public var category: ErrorCategory {
        switch self {
        case .sourceLimitReached, .externalDrivesRequirePro: .licensing
        case .sourceUnreadable: .permissionDenied
        case .unsupportedFile: .unsupported
        }
    }

    public var description: String {
        switch self {
        case .sourceLimitReached(let limit): "Free includes up to \(limit) folders"
        case .externalDrivesRequirePro: "External drives need Pro"
        case .sourceUnreadable: "Glint cannot read this folder"
        case .unsupportedFile: "This file type is not supported"
        }
    }
}

/// Tunables for the indexing pipeline.
public struct IndexerOptions: Sendable, Hashable {
    /// Files extracted at the same time (CPU stage).
    public var concurrentFiles: Int
    /// Inputs per embedding call when the user is not typing.
    public var embeddingBatchSize: Int
    /// Chunks kept per file; protects the index from pathological files.
    public var maxChunksPerFile: Int
    /// Index video only on AC power.
    public var videoOnlyOnPower: Bool
    /// Fuse a chunk's keyword text (OCR) into its image or video input, so screenshots are
    /// found by what they say as well as what they show.
    public var fuseTextIntoMedia: Bool
    /// How long to wait between watcher events before applying them.
    public var watcherLatency: TimeInterval

    public init(
        concurrentFiles: Int = max(2, ProcessInfo.processInfo.activeProcessorCount / 2),
        embeddingBatchSize: Int = 16,
        maxChunksPerFile: Int = 4_000,
        videoOnlyOnPower: Bool = false,
        fuseTextIntoMedia: Bool = true,
        watcherLatency: TimeInterval = 1
    ) {
        self.concurrentFiles = concurrentFiles
        self.embeddingBatchSize = embeddingBatchSize
        self.maxChunksPerFile = maxChunksPerFile
        self.videoOnlyOnPower = videoOnlyOnPower
        self.fuseTextIntoMedia = fuseTextIntoMedia
        self.watcherLatency = watcherLatency
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

/// Decides when indexing should pause to protect battery and thermals.
public protocol PowerMonitoring: Sendable {
    func pauseReason() -> PauseReason?
    var isOnBattery: Bool { get }
}

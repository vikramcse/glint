import Foundation
import GlintCore

/// Errors thrown by content extractors. Descriptions never include paths or file contents.
public enum ExtractionError: GlintError, Equatable {
    /// The file could not be opened; the category says why (permission, missing, other).
    case unreadable(ErrorCategory)
    /// No extractor handles this content type, or the format variant is unsupported
    /// (for example a password-protected PDF or a binary file named `.txt`).
    case unsupported
    /// The file is larger than the configured limit.
    case tooLarge(limit: Int64)
    /// The file is damaged or not what its type claims.
    case corrupt
    /// The file has no content to index.
    case empty
    /// Extraction was cancelled.
    case cancelled

    public var category: ErrorCategory {
        switch self {
        case .unreadable(let category): category
        case .unsupported, .tooLarge: .unsupported
        case .corrupt, .empty: .corrupt
        case .cancelled: .cancelled
        }
    }

    public var description: String {
        switch self {
        case .unreadable(let category): "File unreadable (\(category.rawValue))"
        case .unsupported: "Unsupported content"
        case .tooLarge(let limit): "File exceeds \(limit) bytes"
        case .corrupt: "File is corrupt"
        case .empty: "File is empty"
        case .cancelled: "Extraction cancelled"
        }
    }

    /// Maps any error thrown while extracting to an `ExtractionError`.
    public static func wrap(_ error: any Error) -> ExtractionError {
        if let error = error as? ExtractionError { return error }
        switch error.glintCategory {
        case .cancelled: return .cancelled
        case .permissionDenied: return .unreadable(.permissionDenied)
        case .notFound: return .unreadable(.notFound)
        case .corrupt: return .corrupt
        default: return .corrupt
        }
    }

    /// Checks that `url` exists and is readable before any framework gets a chance to fail vaguely.
    static func checkReadable(_ url: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ExtractionError.unreadable(.notFound)
        }
        guard manager.isReadableFile(atPath: url.path) else {
            throw ExtractionError.unreadable(.permissionDenied)
        }
    }

    /// Size on disk, or 0 for packages and unreadable attributes.
    static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return 0 }
        return Int64(values?.fileSize ?? 0)
    }
}

/// Wraps a pull-based producer in an `AsyncThrowingStream`. Chunks are produced only when the
/// consumer asks for the next one, so large files never buffer more than one chunk ahead,
/// and the producer sees the consumer's task cancellation.
func lazyChunkStream(
    _ next: @escaping @Sendable () async throws -> Chunk?
) -> AsyncThrowingStream<Chunk, any Error> {
    AsyncThrowingStream(unfolding: {
        do {
            try Task.checkCancellation()
            return try await next()
        } catch {
            throw ExtractionError.wrap(error)
        }
    })
}

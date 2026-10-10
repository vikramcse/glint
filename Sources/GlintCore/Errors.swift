import Foundation

/// Broad error categories. Each module throws its own typed errors; the UI maps categories
/// (and a few specific errors) to user-facing messages in one place (`ErrorPresenter`).
public enum ErrorCategory: String, Sendable, Hashable {
    case permissionDenied
    case notFound
    case unsupported
    case corrupt
    case storage
    case model
    case network
    case licensing
    case cancelled
    case `internal`
}

/// Implemented by every module's error type.
public protocol GlintError: Error, Sendable, CustomStringConvertible {
    var category: ErrorCategory { get }
}

/// An action needs a Pro feature. Thrown by services; the UI responds with the upgrade sheet.
public enum EntitlementError: GlintError, Equatable {
    case sourceLimitReached(limit: Int)
    case externalDrivesRequirePro
    case itemLimitReached(limit: Int)

    public var category: ErrorCategory { .licensing }

    public var description: String {
        switch self {
        case .sourceLimitReached(let limit): "Source limit of \(limit) reached"
        case .externalDrivesRequirePro: "External drives need Pro"
        case .itemLimitReached(let limit): "Item limit of \(limit) reached"
        }
    }
}

extension Error {
    /// Category of any error, mapping common system errors.
    public var glintCategory: ErrorCategory {
        if let error = self as? any GlintError { return error.category }
        if self is CancellationError { return .cancelled }
        let nsError = self as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .permissionDenied
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .notFound
            case NSFileReadCorruptFileError: return .corrupt
            default: break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return .permissionDenied
        }
        if nsError.domain == NSURLErrorDomain { return .network }
        return .internal
    }
}

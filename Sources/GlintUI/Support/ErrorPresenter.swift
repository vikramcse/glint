import Foundation
import GlintCore
import GlintSearch

/// The one place errors become user-facing text.
public enum ErrorPresenter {
    public static func message(for error: any Error) -> String {
        if let error = error as? SearchError { return searchMessage(error) }
        if let error = error as? RemoteStorageError { return remoteMessage(error) }
        return categoryMessage(error.glintCategory)
    }

    private static func remoteMessage(_ error: RemoteStorageError) -> String {
        switch error {
        case .unreachable: categoryMessage(.network)
        case .unauthorized(let detail): String(localized: "The service didn’t accept these credentials. \(detail)")
        case .notFound(let detail): String(localized: "Not found. \(detail)")
        case .misconfigured(let detail): detail
        case .service(let status, let detail): String(localized: "The service returned an error (\(status)). \(detail)")
        }
    }

    private static func searchMessage(_ error: SearchError) -> String {
        switch error {
        case .encoderUnavailable:
            String(localized: "The search model is still loading. Keyword results are shown meanwhile.")
        case .noExample:
            String(localized: "Glint couldn’t read anything to compare in that file.")
        }
    }

    private static func categoryMessage(_ category: ErrorCategory) -> String {
        switch category {
        case .permissionDenied:
            String(
                localized: "Glint doesn’t have permission to read this. You can grant access in System Settings › Privacy & Security.")
        case .notFound:
            String(localized: "The file is no longer there. It may have been moved or deleted.")
        case .unsupported:
            String(localized: "Glint can’t read this kind of file yet.")
        case .corrupt:
            String(localized: "The file appears to be damaged.")
        case .storage:
            String(localized: "Glint couldn’t update its index. Check that your disk has free space.")
        case .model:
            String(localized: "The search model isn’t available right now.")
        case .network:
            String(localized: "Glint couldn’t reach the server. Check your internet connection and try again.")
        case .cancelled:
            String(localized: "Cancelled.")
        case .internal:
            String(localized: "Something went wrong. Please try again.")
        }
    }
}

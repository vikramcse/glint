import Foundation
import GlintCore
import GlintLicensing
import GlintSearch

/// The one place errors become user-facing text.
public enum ErrorPresenter {
    public static func message(for error: any Error) -> String {
        if let error = error as? LicenseError { return message(for: error) }
        if let error = error as? SearchError {
            switch error {
            case .encoderUnavailable:
                return String(localized: "The search model is still loading. Keyword results are shown meanwhile.")
            case .noExample:
                return String(localized: "Glint couldn’t read anything to compare in that file.")
            }
        }
        if let error = error as? EntitlementError {
            switch error {
            case .sourceLimitReached(let limit):
                return String(localized: "Glint Free includes up to \(limit) folders. Upgrade to Pro to add more.")
            case .externalDrivesRequirePro:
                return String(localized: "External drives need Glint Pro.")
            case .itemLimitReached(let limit):
                return String(localized: "Glint Free indexes up to \(limit) items. Upgrade to Pro to index everything.")
            }
        }
        switch error.glintCategory {
        case .licensing:
            return String(localized: "This needs Glint Pro.")
        case .permissionDenied:
            return String(
                localized: "Glint doesn’t have permission to read this. You can grant access in System Settings › Privacy & Security.")
        case .notFound:
            return String(localized: "The file is no longer there. It may have been moved or deleted.")
        case .unsupported:
            return String(localized: "Glint can’t read this kind of file yet.")
        case .corrupt:
            return String(localized: "The file appears to be damaged.")
        case .storage:
            return String(localized: "Glint couldn’t update its index. Check that your disk has free space.")
        case .model:
            return String(localized: "The search model isn’t available right now.")
        case .network:
            return String(localized: "Glint couldn’t reach the server. Check your internet connection and try again.")
        case .cancelled:
            return String(localized: "Cancelled.")
        case .internal:
            return String(localized: "Something went wrong. Please try again.")
        }
    }

    public static func message(for error: LicenseError) -> String {
        switch error {
        case .invalidKey: String(localized: "That doesn’t look like a Glint license key.")
        case .tampered: String(localized: "This license key isn’t valid.")
        case .wrongProduct: String(localized: "This key is for a different product.")
        case .wrongVersion: String(localized: "This key is for a different version of Glint.")
        case .wrongDevice: String(localized: "This activation belongs to another Mac. Activate the key again on this Mac.")
        case .seatLimitReached:
            String(localized: "This license is already active on 2 Macs. Deactivate one in its Settings or on the license page.")
        case .revoked: String(localized: "This license was refunded and is no longer active.")
        case .network: String(localized: "Glint couldn’t reach the license server. Check your connection and try again.")
        case .server: String(localized: "The license server had a problem. Please try again later.")
        case .storage: String(localized: "Glint couldn’t save the license to your keychain.")
        }
    }
}

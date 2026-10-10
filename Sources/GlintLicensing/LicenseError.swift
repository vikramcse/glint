import Foundation
import GlintCore

/// Everything that can go wrong buying, activating or verifying a license.
public enum LicenseError: GlintError, Equatable {
    /// The text is not a Glint license key.
    case invalidKey
    /// The signature does not match the payload.
    case tampered
    /// A valid key for a different product.
    case wrongProduct
    /// A valid key for another major version (for example a 2.x key in 1.x).
    case wrongVersion
    /// An activation token issued to another Mac.
    case wrongDevice
    /// Every seat of this license is in use.
    case seatLimitReached
    /// The license was refunded or charged back.
    case revoked
    /// The license server could not be reached.
    case network
    /// The license server answered with an unexpected status.
    case server(status: Int)
    /// The Keychain refused to store or read a value.
    case storage(status: Int32)

    public var category: ErrorCategory {
        switch self {
        case .network: .network
        case .storage: .storage
        default: .licensing
        }
    }

    public var description: String {
        switch self {
        case .invalidKey: "invalid license key"
        case .tampered: "license signature mismatch"
        case .wrongProduct: "license is for another product"
        case .wrongVersion: "license is for another major version"
        case .wrongDevice: "activation belongs to another install"
        case .seatLimitReached: "seat limit reached"
        case .revoked: "license revoked"
        case .network: "license server unreachable"
        case .server(let status): "license server error \(status)"
        case .storage(let status): "keychain error \(status)"
        }
    }
}

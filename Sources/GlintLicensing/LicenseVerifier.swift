import CryptoKit
import Foundation

/// Verifies license keys and activation tokens offline against a compiled-in public key.
public struct LicenseVerifier: Sendable {
    private let publicKey: Curve25519.Signing.PublicKey

    public init(publicKey: Curve25519.Signing.PublicKey) {
        self.publicKey = publicKey
    }

    /// Creates a verifier from a base64 raw public key.
    public init(publicKeyBase64: String) throws {
        guard let data = Data(base64Encoded: publicKeyBase64) else { throw LicenseError.invalidKey }
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: data)
        } catch {
            throw LicenseError.invalidKey
        }
    }

    /// A verifier using the key compiled into this build.
    public static func production() throws -> LicenseVerifier {
        try LicenseVerifier(publicKeyBase64: LicensePublicKey.base64)
    }

    /// Verifies `token` and returns its payload.
    ///
    /// - Parameters:
    ///   - kind: When set, the token must be of this kind.
    ///   - installID: When set and the token is an activation, it must belong to this install.
    /// - Throws: `LicenseError` describing the first check that failed.
    public func verify(
        _ token: String,
        kind: LicensePayload.Kind? = nil,
        installID: String? = nil
    ) throws -> LicensePayload {
        guard let parts = LicenseTokenCodec.split(token) else { throw LicenseError.invalidKey }
        guard publicKey.isValidSignature(parts.signature, for: parts.payload) else { throw LicenseError.tampered }
        let payload: LicensePayload
        do {
            payload = try LicenseTokenCodec.decodePayload(parts.payload)
        } catch {
            throw LicenseError.invalidKey
        }
        guard payload.product == LicensePayload.currentProduct else { throw LicenseError.wrongProduct }
        guard payload.majorVersion == LicensePayload.currentMajorVersion else { throw LicenseError.wrongVersion }
        if let kind, payload.kind != kind { throw LicenseError.invalidKey }
        if payload.kind == .activation {
            guard let tokenInstall = payload.installID else { throw LicenseError.invalidKey }
            if let installID, tokenInstall != installID { throw LicenseError.wrongDevice }
        }
        return payload
    }
}

/// Signs payloads. Used by the license server, the `glint-license` tool and tests — the app
/// itself never holds a private key.
public struct LicenseSigner: Sendable {
    private let privateKey: Curve25519.Signing.PrivateKey

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    /// Creates a signer from a base64 raw private key.
    public init(privateKeyBase64: String) throws {
        let trimmed = privateKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed) else { throw LicenseError.invalidKey }
        do {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        } catch {
            throw LicenseError.invalidKey
        }
    }

    public var publicKey: Curve25519.Signing.PublicKey { privateKey.publicKey }

    /// Returns the `GLINT1-…` token for `payload`.
    public func sign(_ payload: LicensePayload) throws -> String {
        let data = try LicenseTokenCodec.encodePayload(payload)
        let signature = try privateKey.signature(for: data)
        return LicenseTokenCodec.token(payload: data, signature: signature)
    }
}

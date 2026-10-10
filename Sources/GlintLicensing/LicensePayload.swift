import CryptoKit
import Foundation

/// The signed contents of a license key or an activation token.
///
/// A license key (`kind == .license`) is what the buyer receives. An activation token
/// (`kind == .activation`) is what the license server returns for one install; it carries the
/// install id so it cannot be copied to another Mac.
public struct LicensePayload: Codable, Sendable, Hashable {
    /// Whether the token is a buyer's key or a per-install activation.
    public enum Kind: String, Codable, Sendable, Hashable {
        case license
        case activation
    }

    public static let currentProduct = "glint-pro"
    public static let currentMajorVersion = 1
    public static let defaultSeats = 2

    public var licenseID: String
    public var product: String
    public var majorVersion: Int
    public var seats: Int
    public var issuedAt: Date
    /// SHA-256 of the lowercased buyer email, hex encoded. Never the email itself.
    public var emailHash: String
    /// The install this activation belongs to; `nil` for license keys.
    public var installID: String?
    public var kind: Kind

    public init(
        licenseID: String,
        product: String = LicensePayload.currentProduct,
        majorVersion: Int = LicensePayload.currentMajorVersion,
        seats: Int = LicensePayload.defaultSeats,
        issuedAt: Date,
        emailHash: String,
        installID: String? = nil,
        kind: Kind = .license
    ) {
        self.licenseID = licenseID
        self.product = product
        self.majorVersion = majorVersion
        self.seats = seats
        self.issuedAt = issuedAt
        self.emailHash = emailHash
        self.installID = installID
        self.kind = kind
    }

    /// Hashes an email the way license payloads store it.
    public static func hashEmail(_ email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns an activation payload for `installID` derived from this license key.
    public func activation(for installID: String, at date: Date) -> LicensePayload {
        var copy = self
        copy.installID = installID
        copy.kind = .activation
        copy.issuedAt = date
        return copy
    }
}

/// Encodes and decodes the `GLINT1-<payload>.<signature>` wire format.
public enum LicenseTokenCodec {
    public static let prefix = "GLINT1-"

    /// Canonical payload bytes: JSON with sorted keys and whole-second dates.
    public static func encodePayload(_ payload: LicensePayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int64(date.timeIntervalSince1970.rounded(.down)))
        }
        return try encoder.encode(payload)
    }

    public static func decodePayload(_ data: Data) throws -> LicensePayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return Date(timeIntervalSince1970: TimeInterval(try container.decode(Int64.self)))
        }
        return try decoder.decode(LicensePayload.self, from: data)
    }

    /// Joins payload bytes and signature into a token string.
    public static func token(payload: Data, signature: Data) -> String {
        prefix + payload.base64URLEncodedString() + "." + signature.base64URLEncodedString()
    }

    /// Splits a token into payload bytes and signature, or returns `nil` if it is malformed.
    /// Whitespace and line breaks (common when keys are pasted from email) are ignored.
    public static func split(_ token: String) -> (payload: Data, signature: Data)? {
        let cleaned = token.filter { !$0.isWhitespace }
        guard cleaned.hasPrefix(prefix) else { return nil }
        let body = cleaned.dropFirst(prefix.count)
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
            let payload = Data(base64URLEncoded: String(parts[0])),
            let signature = Data(base64URLEncoded: String(parts[1]))
        else { return nil }
        return (payload, signature)
    }
}

extension Data {
    /// Base64url without padding (RFC 4648 §5).
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes base64url with or without padding.
    public init?(base64URLEncoded string: String) {
        var base64 =
            string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }
}

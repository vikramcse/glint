import CryptoKit
import Foundation

/// AWS Signature Version 4 for S3 and S3-compatible services.
struct SigV4Signer: Sendable {
    var accessKeyID: String
    var secretAccessKey: String
    var region: String
    var service = "s3"

    /// SHA-256 of an empty body, the payload hash of every GET.
    static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// Adds `x-amz-date`, `x-amz-content-sha256` and `Authorization` to `request`. Every header
    /// already on the request is signed, plus `host`. The URL's path and query must already be
    /// encoded with `SigV4Signer.encode` (as `S3Storage` builds them).
    func sign(_ request: inout URLRequest, date: Date, payloadHash: String = emptyPayloadHash) {
        let amzDate = Self.timestamp(date)
        let day = String(amzDate.prefix(8))
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        headers["host"] = Self.hostHeader(components)
        let names = headers.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let canonicalRequest = [
            request.httpMethod ?? "GET",
            components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath,
            Self.canonicalQuery(components.percentEncodedQuery),
            names.map { "\($0):\(headers[$0] ?? "")\n" }.joined(),
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8)))]
            .joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
    }

    /// Percent-encodes everything but RFC 3986 unreserved characters (and `/` when `keepSlash`).
    static func encode(_ value: String, keepSlash: Bool = false) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if keepSlash { allowed.insert("/") }
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// `name=value` pairs sorted by name, then value; each is already encoded.
    static func canonicalQuery(_ query: String?) -> String {
        guard let query, !query.isEmpty else { return "" }
        let pairs: [(name: String, value: String)] = query.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        }
        let sorted = pairs.sorted { $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name }
        return sorted.map { $0.name + "=" + $0.value }.joined(separator: "&")
    }

    private static func hostHeader(_ components: URLComponents) -> String {
        let host = components.percentEncodedHost ?? ""
        guard let port = components.port else { return host }
        let isDefault = (components.scheme == "https" && port == 443) || (components.scheme == "http" && port == 80)
        return isDefault ? host : "\(host):\(port)"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

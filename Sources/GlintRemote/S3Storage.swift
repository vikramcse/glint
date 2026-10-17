import Foundation
import GlintCore

/// An S3 bucket, or a prefix in one: AWS S3, Cloudflare R2, Backblaze B2, MinIO and other
/// S3-compatible services. Lists with ListObjectsV2 and downloads with GetObject, signed with SigV4.
struct S3Storage: RemoteStorage {
    let config: RemoteSourceConfig
    let signer: SigV4Signer
    let http: RemoteHTTP
    var now: @Sendable () -> Date = { Date() }

    init(config: RemoteSourceConfig, secretAccessKey: String, http: RemoteHTTP) throws {
        guard let bucket = config.bucket, !bucket.isEmpty else { throw RemoteStorageError.misconfigured("Enter a bucket name.") }
        guard let accessKeyID = config.accessKeyID, !accessKeyID.isEmpty, !secretAccessKey.isEmpty else {
            throw RemoteStorageError.misconfigured("Enter an access key and secret key.")
        }
        guard let endpoint = config.endpoint.flatMap(URL.init(string:)), ["https", "http"].contains(endpoint.scheme),
            endpoint.host() != nil
        else { throw RemoteStorageError.misconfigured("Enter the endpoint as a URL, such as https://s3.us-east-1.amazonaws.com.") }
        self.config = config
        self.http = http
        signer = SigV4Signer(
            accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
            region: config.region.flatMap { $0.isEmpty ? nil : $0 } ?? "us-east-1")
    }

    /// The key prefix of the source's folder: `photos/2024/`, or empty for the whole bucket.
    var prefix: String {
        let folder = config.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return folder.isEmpty ? "" : folder + "/"
    }

    func connect() async throws -> RemoteSourceConfig {
        _ = try await page(continuation: nil, maxKeys: 1)
        return config
    }

    func list() async throws -> [RemoteObject] {
        var objects: [RemoteObject] = []
        var continuation: String?
        repeat {
            let result = try await page(continuation: continuation, maxKeys: 1_000)
            objects += result.objects.compactMap { object in
                guard object.key.hasPrefix(prefix), !object.key.hasSuffix("/") else { return nil }
                var relative = object
                relative.key = String(object.key.dropFirst(prefix.count))
                return relative.key.isEmpty ? nil : relative
            }
            continuation = result.isTruncated ? result.nextContinuationToken : nil
            try Task.checkCancellation()
        } while continuation != nil
        return objects
    }

    func download(key: String, to directory: URL) async throws -> URL {
        let destination = localFileURL(for: key.split(separator: "/").last.map(String.init) ?? key, in: directory)
        let url = try objectURL(key: prefix + key, query: [])
        try await http.download({ signedRequest(url) }, to: destination)
        return destination
    }

    // MARK: Requests

    private func page(continuation: String?, maxKeys: Int) async throws -> ListResult {
        var query = [("list-type", "2"), ("max-keys", String(maxKeys))]
        if !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let continuation { query.append(("continuation-token", continuation)) }
        let url = try objectURL(key: nil, query: query)
        let data = try await http.data { signedRequest(url) }
        return try ListResult.parse(data)
    }

    private func signedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        signer.sign(&request, date: now())
        return request
    }

    /// Virtual-hosted (`bucket.endpoint/key`) or path-style (`endpoint/bucket/key`) URL, encoded
    /// exactly as SigV4 signs it.
    func objectURL(key: String?, query: [(String, String)]) throws -> URL {
        guard let endpoint = config.endpoint.flatMap(URL.init(string:)),
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), let host = endpoint.host(),
            let bucket = config.bucket
        else { throw RemoteStorageError.misconfigured("The endpoint is not a valid URL.") }
        let base = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var segments = base.isEmpty ? [] : [base]
        if config.pathStyle {
            segments.append(SigV4Signer.encode(bucket))
        } else {
            components.host = "\(bucket).\(host)"
        }
        if let key { segments.append(SigV4Signer.encode(key, keepSlash: true)) }
        components.percentEncodedPath = "/" + segments.joined(separator: "/")
        if config.pathStyle, key == nil { components.percentEncodedPath += "/" }
        components.percentEncodedQuery =
            query.isEmpty ? nil : query.map { "\(SigV4Signer.encode($0.0))=\(SigV4Signer.encode($0.1))" }.joined(separator: "&")
        guard let url = components.url else { throw RemoteStorageError.misconfigured("The bucket or key makes an invalid URL.") }
        return url
    }
}

/// One page of a ListObjectsV2 response.
struct ListResult {
    var objects: [RemoteObject] = []
    var isTruncated = false
    var nextContinuationToken: String?

    static func parse(_ data: Data) throws -> ListResult {
        let delegate = ListParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw RemoteStorageError.service(status: 200, message: "Unreadable bucket listing")
        }
        return delegate.result
    }
}

private final class ListParser: NSObject, XMLParserDelegate {
    var result = ListResult()
    private var text = ""
    private var key: String?
    private var size: Int64 = 0
    private var modified = Date.distantPast
    private var inContents = false

    func parser(
        _ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        text = ""
        if element == "Contents" {
            inContents = true
            key = nil
            size = 0
            modified = .distantPast
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "Key" where inContents: key = text
        case "Size" where inContents: size = Int64(text) ?? 0
        case "LastModified" where inContents: modified = Self.date(text) ?? .distantPast
        case "Contents":
            inContents = false
            if let key { result.objects.append(RemoteObject(key: key, size: size, modified: modified)) }
        case "IsTruncated": result.isTruncated = text == "true"
        case "NextContinuationToken": result.nextContinuationToken = text
        default: break
        }
    }

    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

import Foundation

/// A parsed HTTP/1.1 request. Header names are lowercased.
public struct HTTPRequest: Sendable, Hashable {
    public var method: String
    /// The path without the query string, e.g. `/v1/search`.
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }
}

/// An HTTP response. Every response closes the connection and is never cached.
public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// The wire form, with `Content-Length`, `Connection: close` and `Cache-Control: no-store`.
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        if !body.isEmpty, all["Content-Type"] == nil { all["Content-Type"] = "application/json; charset=utf-8" }
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(for status: Int) -> String {
        reasons[status] ?? "Status"
    }

    private static let reasons: [Int: String] = [
        200: "OK",
        400: "Bad Request",
        401: "Unauthorized",
        402: "Payment Required",
        403: "Forbidden",
        404: "Not Found",
        405: "Method Not Allowed",
        413: "Payload Too Large",
        415: "Unsupported Media Type",
        422: "Unprocessable Content",
        431: "Request Header Fields Too Large",
        500: "Internal Server Error",
        501: "Not Implemented",
        503: "Service Unavailable",
    ]
}

/// Result of feeding bytes received so far to the parser.
public enum HTTPParseResult: Sendable, Hashable {
    case incomplete
    case complete(HTTPRequest)
    /// The request is malformed or too large; respond with this status and close.
    case failure(status: Int)
}

/// An incremental, size-limited HTTP/1.1 request parser. Chunked bodies are not supported;
/// clients send `Content-Length` (every JSON client does).
public enum HTTPRequestParser {
    public static func parse(_ data: Data, maxHeaderBytes: Int = 16_384, maxBodyBytes: Int = 65_536) -> HTTPParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else {
            return data.count > maxHeaderBytes ? .failure(status: 431) : .incomplete
        }
        guard headerEnd.lowerBound <= maxHeaderBytes,
            let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8)
        else { return .failure(status: headerEnd.lowerBound > maxHeaderBytes ? 431 : 400) }

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .failure(status: 400) }
        guard let headers = parseHeaders(lines.dropFirst()) else { return .failure(status: 400) }
        if headers["transfer-encoding"] != nil { return .failure(status: 501) }

        guard let length = contentLength(headers) else { return .failure(status: 400) }
        if length > maxBodyBytes { return .failure(status: 413) }
        let bodyStart = headerEnd.upperBound
        let available = data.endIndex - bodyStart
        if available < length { return .incomplete }
        let body = Data(data[bodyStart..<(bodyStart + length)])

        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, headers: headers, body: body))
    }

    /// Lowercased header names to values, or nil when a line is malformed.
    private static func parseHeaders(_ lines: ArraySlice<String>) -> [String: String]? {
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            headers[name] = value
        }
        return headers
    }

    /// The declared body length (0 when absent), or nil when it is not a valid length.
    private static func contentLength(_ headers: [String: String]) -> Int? {
        guard let declared = headers["content-length"] else { return 0 }
        guard let value = Int(declared), value >= 0 else { return nil }
        return value
    }
}

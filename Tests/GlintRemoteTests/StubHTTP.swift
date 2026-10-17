import Foundation
import Testing

@testable import GlintRemote

/// Every suite in this target nests in here: they share `StubURLProtocol`'s one handler, so
/// they must not run in parallel.
@Suite(.serialized) enum RemoteTests {}

/// A fake server for URLSession: each test registers a handler that answers requests.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]

        static func text(_ text: String, status: Int = 200) -> Response {
            Response(status: status, body: Data(text.utf8))
        }
    }

    typealias Handler = @Sendable (URLRequest) throws -> Response

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func serve(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    static var requests: [URLRequest] { lock.withLock { recorded } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = self.request
        // URLSession moves the body into a stream; read it back so handlers can inspect it.
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            request.httpBody = data
        }
        let handler = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.handler
        }
        do {
            guard let handler, let url = request.url else { throw URLError(.cannotConnectToHost) }
            let response = try handler(request)
            guard
                let http = HTTPURLResponse(
                    url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)
            else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func http() -> RemoteHTTP {
        RemoteHTTP(session: session(), attempts: 3, baseDelay: .milliseconds(1))
    }
}

extension URLRequest {
    /// Query parameters, decoded.
    var query: [String: String] {
        var result: [String: String] = [:]
        guard let url else { return [:] }
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { result[item.name] = item.value }
        return result
    }

}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-remote-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

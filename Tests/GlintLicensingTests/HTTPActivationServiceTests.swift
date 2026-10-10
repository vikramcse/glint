import Foundation
import Testing

@testable import GlintLicensing

/// Serves canned responses keyed by host, so parallel tests don't interfere.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Response] = [:]
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]

    static func stub(host: String, status: Int, json: String = "{}") {
        lock.withLock { responses[host] = Response(status: status, body: Data(json.utf8)) }
    }

    static func recorded(host: String) -> [URLRequest] {
        lock.withLock { requests[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let response = Self.lock.withLock { () -> Response? in
            Self.requests[host, default: []].append(request)
            return Self.responses[host]
        }
        guard let response, let url = request.url,
            let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("HTTP activation service")
struct HTTPActivationServiceTests {
    func service(host: String) throws -> HTTPActivationService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return HTTPActivationService(
            baseURL: try #require(URL(string: "https://\(host)")), session: URLSession(configuration: configuration)
        )
    }

    @Test func activationReturnsToken() async throws {
        StubURLProtocol.stub(host: "ok.test", status: 200, json: #"{"activation":"GLINT1-a.b"}"#)
        let token = try await service(host: "ok.test").activate(key: "K", installID: "I")
        #expect(token == "GLINT1-a.b")
        let request = try #require(StubURLProtocol.recorded(host: "ok.test").first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/activate")
    }

    @Test(arguments: [
        (409, LicenseError.seatLimitReached),
        (410, .revoked),
        (422, .invalidKey),
        (500, .server(status: 500)),
    ])
    func mapsStatusCodes(status: Int, expected: LicenseError) async throws {
        let host = "status\(status).test"
        StubURLProtocol.stub(host: host, status: status)
        let service = try service(host: host)
        await #expect(throws: expected) { _ = try await service.activate(key: "K", installID: "I") }
    }

    @Test func unreachableServerIsNetworkError() async throws {
        let service = try service(host: "down.test")
        await #expect(throws: LicenseError.network) { _ = try await service.isRevoked(activationToken: "T") }
    }

    @Test func validateReadsRevokedFlag() async throws {
        StubURLProtocol.stub(host: "validate.test", status: 200, json: #"{"revoked":true}"#)
        #expect(try await service(host: "validate.test").isRevoked(activationToken: "T"))
        let request = try #require(StubURLProtocol.recorded(host: "validate.test").first)
        #expect(request.url?.query == "activation=T")
    }
}

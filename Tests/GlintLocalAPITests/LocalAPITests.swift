import Foundation
import GlintCore
import Testing

@testable import GlintLocalAPI

@Suite("HTTP parser")
struct HTTPParserTests {
    @Test func parsesRequestWithBody() {
        let raw = "POST /v1/search?x=1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: 4\r\nX-Case: Yes\r\n\r\nabcd"
        guard case .complete(let request) = HTTPRequestParser.parse(Data(raw.utf8)) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/v1/search")
        #expect(request.headers["x-case"] == "Yes")
        #expect(request.body == Data("abcd".utf8))
    }

    @Test func waitsForTheRestOfTheBody() {
        let raw = "POST /v1/search HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc"
        #expect(HTTPRequestParser.parse(Data(raw.utf8)) == .incomplete)
        #expect(HTTPRequestParser.parse(Data("GET / HTTP/1.1\r\nHost: x".utf8)) == .incomplete)
    }

    @Test func rejectsOversizedAndMalformedRequests() {
        let bigHeader = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000)
        #expect(HTTPRequestParser.parse(Data(bigHeader.utf8)) == .failure(status: 431))
        let bigBody = "POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n"
        #expect(HTTPRequestParser.parse(Data(bigBody.utf8)) == .failure(status: 413))
        #expect(HTTPRequestParser.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .failure(status: 501))
        #expect(HTTPRequestParser.parse(Data("NONSENSE\r\n\r\n".utf8)) == .failure(status: 400))
        #expect(HTTPRequestParser.parse(Data("GET / HTTP/1.1\r\nContent-Length: -3\r\n\r\n".utf8)) == .failure(status: 400))
    }

    @Test func responsesCloseAndAreNotCached() {
        let text = String(decoding: HTTPResponse(status: 200, body: Data("{}".utf8)).serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Connection: close"))
        #expect(text.contains("Cache-Control: no-store"))
        #expect(text.contains("Content-Length: 2"))
        #expect(text.hasSuffix("\r\n\r\n{}"))
    }
}

@Suite("Local API router")
struct LocalAPIRouterTests {
    @Test func searchReturnsPagesTimestampsAndSnippets() async throws {
        let harness = try await APIHarness.make()
        let response = await harness.send(APIHarness.request("POST", "/v1/search", body: #"{"query":"deadline"}"#))
        #expect(response.status == 200)
        let audio = try #require(response.results.first { $0["kind"] as? String == "audio" })
        #expect(audio["name"] as? String == "standup.m4a")
        #expect(audio["start"] as? Double == 724)
        #expect((audio["snippet"] as? String)?.contains("deadline") == true)

        let pdf = await harness.send(APIHarness.request("POST", "/v1/search", body: #"{"query":"pricing chart"}"#))
        #expect(pdf.results.first?["page"] as? Int == 3)
    }

    @Test func searchAppliesKindsLimitAndDates() async throws {
        let harness = try await APIHarness.make()
        let images = await harness.send(APIHarness.request("POST", "/v1/search", body: #"{"query":"beach","kinds":["image"],"limit":1}"#))
        #expect(images.status == 200)
        #expect(images.results.count == 1)
        #expect(images.results.allSatisfy { $0["kind"] as? String == "image" })

        let future = await harness.send(APIHarness.request("POST", "/v1/search", body: #"{"query":"beach","modifiedAfter":"2030-01-01"}"#))
        #expect(future.status == 200)
        #expect(future.results.isEmpty)

        let elsewhere = await harness.send(
            APIHarness.request("POST", "/v1/search", body: #"{"query":"beach","folders":["/nowhere"]}"#))
        #expect(elsewhere.results.isEmpty)
    }

    @Test func rejectsBadSearchBodies() async throws {
        let harness = try await APIHarness.make()
        let cases: [(String, String)] = [
            ("not json", "invalid_json"),
            (#"{"query":"   "}"#, "invalid_query"),
            (#"{"query":"x","kinds":["spaceship"]}"#, "invalid_kind"),
            (#"{"query":"x","limit":0}"#, "invalid_limit"),
            (#"{"query":"x","limit":500}"#, "invalid_limit"),
            (#"{"query":"x","modifiedAfter":"yesterday"}"#, "invalid_date"),
            ("{\"query\":\"\(String(repeating: "a", count: 1_001))\"}", "invalid_query"),
        ]
        for (body, code) in cases {
            let response = await harness.send(APIHarness.request("POST", "/v1/search", body: body))
            #expect(response.status == 400, "body: \(body.prefix(40))")
            #expect(response.errorCode == code)
        }
    }

    @Test func authenticationAndOriginChecks() async throws {
        let harness = try await APIHarness.make()
        #expect(await harness.send(APIHarness.request("GET", "/v1/status", token: nil)).status == 401)
        #expect(await harness.send(APIHarness.request("GET", "/v1/status", token: "wrong")).status == 401)
        let browser = APIHarness.request("GET", "/v1/status", extraHeaders: ["Origin": "https://evil.example"])
        #expect(await harness.send(browser).status == 403)
        let rebinding = APIHarness.request("GET", "/v1/status", host: "evil.example:4242")
        #expect(await harness.send(rebinding).status == 403)
        let localhost = APIHarness.request("GET", "/v1/status", host: "localhost:\(APIHarness.port)")
        #expect(await harness.send(localhost).status == 200)
    }

    @Test func statusAndSources() async throws {
        let harness = try await APIHarness.make()
        let status = await harness.send(APIHarness.request("GET", "/v1/status"))
        #expect(status.status == 200)
        #expect(status.json["phase"] as? String == "indexing")
        #expect(status.json["totalIndexed"] as? Int == 3)
        #expect((status.json["indexed"] as? [String: Int])?["pdf"] == 1)

        let sources = await harness.send(APIHarness.request("GET", "/v1/sources"))
        let first = try #require((sources.json["sources"] as? [[String: Any]])?.first)
        #expect(first["path"] as? String == harness.library.path)
        #expect(first["complete"] as? Bool == false)
    }

    @Test func similarFindsNeighboursOfAnIndexedFile() async throws {
        let harness = try await APIHarness.make()
        let path = harness.library.appendingPathComponent("beach.jpg").path
        let response = await harness.send(APIHarness.request("POST", "/v1/similar", body: "{\"path\":\"\(path)\"}"))
        #expect(response.status == 200)
        #expect(response.results.first?["name"] as? String == "sunset.jpg")
        #expect(!response.results.contains { $0["name"] as? String == "beach.jpg" })

        let missing = await harness.send(APIHarness.request("POST", "/v1/similar", body: #"{"path":"/no/such/file.jpg"}"#))
        #expect(missing.status == 404)
        let relative = await harness.send(APIHarness.request("POST", "/v1/similar", body: #"{"path":"beach.jpg"}"#))
        #expect(relative.errorCode == "invalid_path")
    }

    @Test func unknownRoutesAndMethods() async throws {
        let harness = try await APIHarness.make()
        #expect(await harness.send(APIHarness.request("GET", "/v1/nope")).status == 404)
        #expect(await harness.send(APIHarness.request("GET", "/v1/search")).status == 405)
        let wrongType = APIHarness.request(
            "POST", "/v1/search", body: #"{"query":"x"}"#, extraHeaders: ["Content-Type": "text/plain"])
        var request = wrongType
        request.headers["content-type"] = "text/plain"
        #expect(await harness.send(request).status == 415)
    }

    @Test func tokenComparisonIsExact() {
        #expect(LocalAPIRouter.constantTimeEqual("abc", "abc"))
        #expect(!LocalAPIRouter.constantTimeEqual("abc", "abd"))
        #expect(!LocalAPIRouter.constantTimeEqual("abc", "abcd"))
        #expect(!LocalAPIRouter.constantTimeEqual("", "a"))
    }
}

@Suite("Local API credentials")
struct LocalAPICredentialsTests {
    @Test func tokenPersistsWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("api-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("api-token")
        let token = try LocalAPICredentials.loadOrCreateToken(at: url)
        #expect(token.count == 64)
        #expect(try LocalAPICredentials.loadOrCreateToken(at: url) == token)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        #expect(try LocalAPICredentials.rotateToken(at: url) != token)
    }

    @Test func discoveryRoundTripsAndIsRemoved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("api-\(UUID().uuidString)/api.json")
        try LocalAPICredentials.writeDiscovery(LocalAPIDiscovery(port: 5_123, token: "t"), to: url)
        let decoded = try JSONDecoder().decode(LocalAPIDiscovery.self, from: Data(contentsOf: url))
        #expect(decoded.port == 5_123)
        #expect(decoded.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        LocalAPICredentials.removeDiscovery(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite("Local API server", .serialized)
struct LocalAPIServerTests {
    private func call(
        _ port: UInt16, _ method: String, _ path: String, body: Data? = nil, token: String? = APIHarness.token
    ) async throws -> (Int, Data) {
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)\(path)")), timeoutInterval: 10)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    @Test func servesOverLoopbackAndStops() async throws {
        let harness = try await APIHarness.make()
        let server = LocalAPIServer(router: harness.router)
        let port = try await server.start()
        #expect(port > 0)
        #expect(server.port == port)

        let (status, data) = try await call(port, "POST", "/v1/search", body: Data(#"{"query":"beach"}"#.utf8))
        #expect(status == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("beach.jpg"))
        #expect(try await call(port, "GET", "/v1/status", token: nil).0 == 401)

        let huge = Data(("{\"query\":\"" + String(repeating: "a", count: 70_000) + "\"}").utf8)
        let oversized = try? await call(port, "POST", "/v1/search", body: huge)
        // Either an explicit 413 or a closed connection is acceptable; the server must not accept it.
        #expect(oversized == nil || oversized?.0 == 413)

        server.stop()
        #expect(server.port == nil)
        await #expect(throws: (any Error).self) { _ = try await call(port, "GET", "/v1/status") }
    }

    @Test func handlesConcurrentClients() async throws {
        let harness = try await APIHarness.make()
        let server = LocalAPIServer(router: harness.router)
        let port = try await server.start()
        defer { server.stop() }
        let statuses = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<12 { group.addTask { try await call(port, "GET", "/v1/status").0 } }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(statuses == Array(repeating: 200, count: 12))
    }
}

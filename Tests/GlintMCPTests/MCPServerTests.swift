import Foundation
import Testing

@testable import GlintMCP

/// Records requests and returns canned responses.
actor FakeClient: LocalAPIClient {
    var requests: [(path: String, body: JSONValue?)] = []
    var failure: LocalAPIClientError?

    func fail(with error: LocalAPIClientError) { failure = error }

    func get(_ path: String) async throws -> Data {
        requests.append((path, nil))
        if let failure { throw failure }
        switch path {
        case "/v1/status":
            return Data(
                #"{"phase":"paused","pauseReason":"lowBattery","totalIndexed":120,"pending":30,"failed":0,"indexed":{"image":100},"sources":1}"#
                    .utf8)
        default:
            return Data(#"{"sources":[{"path":"/Users/a/Footage","indexed":10,"items":12,"accessible":true,"complete":false}]}"#.utf8)
        }
    }

    func post(_ path: String, body: Data) async throws -> Data {
        requests.append((path, try? JSONValue.parse(body)))
        if let failure { throw failure }
        return Data(
            #"{"results":[{"path":"/Users/a/Festival.mov","name":"Festival.mov","kind":"video","score":0.03,"start":724,"end":729,"indexed":true},{"path":"/Users/a/deck.pdf","name":"deck.pdf","kind":"pdf","score":0.02,"page":3,"snippet":"Pricing chart","indexed":true}]}"#
                .utf8)
    }
}

private func message(_ id: Int, _ method: String, _ params: String = "{}") -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
}

private func decode(_ line: String?) throws -> JSONValue {
    try JSONValue.parse(Data(try #require(line).utf8))
}

@Suite("MCP server")
struct MCPServerTests {
    let client = FakeClient()
    var server: MCPServer { MCPServer(client: client, version: "1.2.3") }

    @Test func initializeNegotiatesVersionAndAdvertisesTools() async throws {
        let response = try decode(
            await server.handle(
                line: message(
                    1, "initialize", #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}"#)))
        #expect(response["id"] == 1)
        #expect(response["result"]?["protocolVersion"] == "2025-06-18")
        #expect(response["result"]?["capabilities"]?["tools"] != nil)
        #expect(response["result"]?["serverInfo"]?["version"] == "1.2.3")

        let older = try decode(await server.handle(line: message(2, "initialize", #"{"protocolVersion":"2024-11-05"}"#)))
        #expect(older["result"]?["protocolVersion"] == "2024-11-05")
        let unknown = try decode(await server.handle(line: message(3, "initialize", #"{"protocolVersion":"1999-01-01"}"#)))
        #expect(unknown["result"]?["protocolVersion"] == .string(MCPServer.protocolVersion))
    }

    @Test func notificationsGetNoReplyAndPingWorks() async throws {
        #expect(await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(await server.handle(line: "   ") == nil)
        let ping = try decode(await server.handle(line: message(7, "ping")))
        #expect(ping["result"] == [:])
    }

    @Test func protocolErrors() async throws {
        #expect(try decode(await server.handle(line: "{not json"))["error"]?["code"] == -32_700)
        #expect(try decode(await server.handle(line: "[]"))["error"]?["code"] == -32_600)
        #expect(try decode(await server.handle(line: #"{"id":1,"method":"ping"}"#))["error"]?["code"] == -32_600)
        #expect(try decode(await server.handle(line: message(4, "resources/list")))["error"]?["code"] == -32_601)
        #expect(try decode(await server.handle(line: message(5, "tools/call", #"{"name":"rm_rf"}"#)))["error"]?["code"] == -32_602)
        // String ids are echoed unchanged.
        let stringID = try decode(await server.handle(line: #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#))
        #expect(stringID["id"] == "abc")
    }

    @Test func toolSchemasAreWellFormed() async throws {
        let list = try decode(await server.handle(line: message(1, "tools/list")))
        guard case .array(let tools)? = list["result"]?["tools"] else {
            Issue.record("tools missing")
            return
        }
        let names = Set(tools.compactMap { $0["name"]?.stringValue })
        #expect(names == ["search_files", "find_similar", "index_status", "list_sources"])
        for tool in tools {
            #expect(tool["inputSchema"]?["type"] == "object")
            #expect(tool["description"]?.stringValue?.isEmpty == false)
            #expect(tool["annotations"]?["readOnlyHint"] == true)
        }
        let search = try #require(tools.first { $0["name"] == "search_files" })
        #expect(search["inputSchema"]?["required"] == ["query"])
        #expect(search["outputSchema"]?["type"] == "object")
    }

    @Test func searchCallsTheAPIAndFormatsMoments() async throws {
        let response = try decode(
            await server.handle(
                line: message(
                    9, "tools/call",
                    #"{"name":"search_files","arguments":{"query":"crowd cheering","kinds":["video"],"limit":99,"modified_after":"2026-01-01"}}"#
                )))
        let result = try #require(response["result"])
        #expect(result["isError"] == false)
        let text = try #require(result["content"]?.decodedArray?.first?["text"]?.stringValue)
        #expect(text.contains("/Users/a/Festival.mov [video, at 12:04]"))
        #expect(text.contains("/Users/a/deck.pdf [pdf, page 3] — Pricing chart"))
        #expect(result["structuredContent"]?["results"] != nil)

        let sent = try #require(await client.requests.first)
        #expect(sent.path == "/v1/search")
        #expect(sent.body?["limit"] == 50)
        #expect(sent.body?["kinds"] == ["video"])
        #expect(sent.body?["modifiedAfter"] == "2026-01-01")
    }

    @Test func statusAndSourcesAreSummarized() async throws {
        let status = try decode(await server.handle(line: message(1, "tools/call", #"{"name":"index_status"}"#)))
        let statusText = status["result"]?["content"]?.decodedArray?.first?["text"]?.stringValue ?? ""
        #expect(statusText.contains("indexed 120 files"))
        #expect(statusText.contains("paused (lowBattery)"))

        let sources = try decode(await server.handle(line: message(2, "tools/call", #"{"name":"list_sources","arguments":{}}"#)))
        #expect(
            sources["result"]?["content"]?.decodedArray?.first?["text"]?.stringValue == "/Users/a/Footage: 10 of 12 files indexed, indexing"
        )
    }

    @Test func toolFailuresAreReadableResults() async throws {
        let missing = try decode(await server.handle(line: message(1, "tools/call", #"{"name":"search_files","arguments":{}}"#)))
        #expect(missing["result"]?["isError"] == true)
        let relative = try decode(
            await server.handle(line: message(2, "tools/call", #"{"name":"find_similar","arguments":{"path":"x.jpg"}}"#)))
        #expect(relative["result"]?["isError"] == true)

        await client.fail(with: .notRunning)
        let down = try decode(await server.handle(line: message(3, "tools/call", #"{"name":"index_status"}"#)))
        #expect(down["result"]?["isError"] == true)
        #expect(down["result"]?["content"]?.decodedArray?.first?["text"]?.stringValue?.contains("Allow apps and agents") == true)
    }

    @Test func responsesAreSingleLines() async throws {
        let line = try #require(await server.handle(line: message(1, "tools/list")))
        #expect(!line.contains("\n"))
    }
}

@Suite("Discovery client")
struct DiscoveryClientTests {
    @Test func missingDiscoveryMeansNotRunning() async {
        let client = DiscoveryHTTPClient(discoveryURL: URL(fileURLWithPath: "/nonexistent/api.json"))
        await #expect(throws: LocalAPIClientError.notRunning) { _ = try await client.get("/v1/status") }
    }

    @Test func closedPortMeansNotRunning() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString).json")
        try Data(#"{"port":1,"token":"t","pid":1,"version":1}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: LocalAPIClientError.notRunning) {
            _ = try await DiscoveryHTTPClient(discoveryURL: url).get("/v1/status")
        }
    }

    @Test func extractsErrorMessages() {
        #expect(DiscoveryHTTPClient.message(in: Data(#"{"error":{"code":"x","message":"Try again"}}"#.utf8)) == "Try again")
        #expect(DiscoveryHTTPClient.message(in: Data("nope".utf8)) == nil)
    }
}

extension JSONValue {
    fileprivate var decodedArray: [JSONValue]? {
        if case .array(let array) = self { array } else { nil }
    }
}

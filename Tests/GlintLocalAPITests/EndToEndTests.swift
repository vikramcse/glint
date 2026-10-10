import Foundation
import GlintMCP
import Testing

@testable import GlintLocalAPI

@Suite("Local API ↔ MCP end to end", .serialized)
struct EndToEndTests {
    @Test func mcpToolCallReachesTheRunningServer() async throws {
        let harness = try await APIHarness.make()
        let server = LocalAPIServer(router: harness.router)
        let port = try await server.start()
        defer { server.stop() }
        let discovery = harness.directory.file("api.json")
        try LocalAPICredentials.writeDiscovery(LocalAPIDiscovery(port: port, token: APIHarness.token), to: discovery)

        let mcp = MCPServer(client: DiscoveryHTTPClient(discoveryURL: discovery, session: URLSession(configuration: .ephemeral)))
        let line = try #require(
            await mcp.handle(
                line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_files","arguments":{"query":"deadline"}}}"#))
        let response = try JSONValue.parse(Data(line.utf8))
        #expect(response["result"]?["isError"] == false)
        guard case .array(let content)? = response["result"]?["content"], let text = content.first?["text"]?.stringValue else {
            Issue.record("missing content")
            return
        }
        #expect(text.contains("standup.m4a [audio, at 12:04]"))

        // A stale token (for example after the app rotated it) reads as a clear error.
        try LocalAPICredentials.writeDiscovery(LocalAPIDiscovery(port: port, token: "stale"), to: discovery)
        let stale = try JSONValue.parse(
            Data(
                try #require(await mcp.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"index_status"}}"#))
                    .utf8))
        #expect(stale["result"]?["isError"] == true)
    }
}

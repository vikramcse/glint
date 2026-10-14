// glint-mcp: an MCP server (stdio) that lets agents search the user's Glint index.
//
//   claude mcp add glint -- /Applications/Glint.app/Contents/MacOS/glint-mcp
//
// Reads one JSON-RPC message per line from stdin and writes one per line to stdout. Logs go
// to stderr only. Requires Glint to be running with the local API turned on.

import Foundation
import GlintMCP

let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--help") || arguments.contains("-h") {
    print(
        "usage: glint-mcp [--discovery PATH]\nAn MCP server over stdio for Glint. Add it to your agent, e.g.:\n"
            + "  claude mcp add glint -- \(CommandLine.arguments[0])"
    )
    exit(0)
}

let discovery: URL
if let index = arguments.firstIndex(of: "--discovery"), arguments.index(after: index) < arguments.endIndex {
    discovery = URL(fileURLWithPath: arguments[arguments.index(after: index)])
} else {
    let support =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    discovery = support.appendingPathComponent("Glint/api.json")
}

let server = MCPServer(client: DiscoveryHTTPClient(discoveryURL: discovery))
setvbuf(stdout, nil, _IOLBF, 0)

// Requests are answered in arrival order; the protocol allows concurrency, but agents rarely need it.
while let line = readLine(strippingNewline: true) {
    if let response = await server.handle(line: line) {
        FileHandle.standardOutput.write(Data((response + "\n").utf8))
    }
}

import Foundation

/// An MCP server (protocol 2025-06-18) over newline-delimited JSON-RPC 2.0 on stdio.
/// `handle(line:)` is pure input → output so the protocol is tested without spawning processes.
public struct MCPServer: Sendable {
    public static let protocolVersion = "2025-06-18"
    public static let supportedVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverName = "glint"

    public let client: any LocalAPIClient
    public let version: String

    public init(client: any LocalAPIClient, version: String = "1.0.0") {
        self.client = client
        self.version = version
    }

    /// Handles one line of input. Returns the response line, or `nil` for notifications.
    public func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONValue.parse(Data(trimmed.utf8)) else {
            return Self.encode(Self.errorResponse(id: .null, code: -32_700, message: "Parse error"))
        }
        guard case .object(let object) = message else {
            // JSON-RPC batches were removed in protocol 2025-06-18.
            return Self.encode(Self.errorResponse(id: .null, code: -32_600, message: "Invalid Request: batches are not supported"))
        }
        let id = object["id"]
        guard object["jsonrpc"] == "2.0", let method = object["method"]?.stringValue else {
            return Self.encode(Self.errorResponse(id: id ?? .null, code: -32_600, message: "Invalid Request"))
        }
        guard let id else { return nil }  // Notification (e.g. notifications/initialized): no reply.

        let params = object["params"] ?? [:]
        switch method {
        case "initialize":
            return Self.encode(Self.result(id: id, initialize(params)))
        case "ping":
            return Self.encode(Self.result(id: id, [:]))
        case "tools/list":
            return Self.encode(Self.result(id: id, ["tools": .array(MCPTools.all)]))
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.encode(Self.errorResponse(id: id, code: -32_602, message: "Invalid params: missing tool name"))
            }
            guard MCPTools.names.contains(name) else {
                return Self.encode(Self.errorResponse(id: id, code: -32_602, message: "Unknown tool: \(name)"))
            }
            let result = await MCPTools(client: client).call(name, arguments: params["arguments"] ?? [:])
            return Self.encode(Self.result(id: id, result))
        default:
            return Self.encode(Self.errorResponse(id: id, code: -32_601, message: "Method not found: \(method)"))
        }
    }

    private func initialize(_ params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue ?? Self.protocolVersion
        let version = Self.supportedVersions.contains(requested) ? requested : Self.protocolVersion
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": .string(Self.serverName), "title": "Glint", "version": .string(self.version)],
            "instructions": """
            Glint searches the user's own files on this Mac: photos, screenshots, moments in videos, \
            speech and sounds in audio, PDF pages and documents. Use search_files with a plain-language \
            description; results include paths, PDF page numbers and video/audio timestamps. Everything \
            stays on the device.
            """,
        ]
    }

    // MARK: Encoding

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func errorResponse(id: JSONValue, code: Int64, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .integer(code), "message": .string(message)]]
    }

    /// One line of JSON (no embedded newlines, as the stdio transport requires).
    static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let line = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
        }
        return line
    }
}

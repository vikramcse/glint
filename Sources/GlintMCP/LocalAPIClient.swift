import Foundation

/// Why a call to Glint's local API failed, phrased for the agent (and its user).
public enum LocalAPIClientError: Error, Sendable, Equatable, CustomStringConvertible {
    case notRunning
    case unauthorized
    case server(status: Int, message: String)
    case invalidResponse

    public var description: String {
        switch self {
        case .notRunning:
            "Glint isn’t running, or its local API is turned off. Open Glint, then turn on "
                + "Settings › Privacy › “Allow apps and agents to search Glint”."
        case .unauthorized:
            "Glint rejected the access token. Quit and reopen Glint, then try again."
        case .server(_, let message):
            message
        case .invalidResponse:
            "Glint returned a response this version of glint-mcp doesn’t understand. Update Glint."
        }
    }
}

/// Talks to Glint's local API. Abstracted so the MCP handler is tested without a network.
public protocol LocalAPIClient: Sendable {
    func get(_ path: String) async throws -> Data
    func post(_ path: String, body: Data) async throws -> Data
}

/// The real client: reads port and token from the discovery file on every call, so it keeps
/// working when Glint restarts on a new port.
public struct DiscoveryHTTPClient: LocalAPIClient {
    struct Discovery: Decodable {
        var port: UInt16
        var token: String
    }

    public let discoveryURL: URL
    let session: URLSession

    public init(discoveryURL: URL, session: URLSession = .shared) {
        self.discoveryURL = discoveryURL
        self.session = session
    }

    public func get(_ path: String) async throws -> Data {
        try await send(path, method: "GET", body: nil)
    }

    public func post(_ path: String, body: Data) async throws -> Data {
        try await send(path, method: "POST", body: body)
    }

    private func send(_ path: String, method: String, body: Data?) async throws -> Data {
        guard let data = try? Data(contentsOf: discoveryURL),
            let discovery = try? JSONDecoder().decode(Discovery.self, from: data),
            let url = URL(string: "http://127.0.0.1:\(discovery.port)\(path)")
        else { throw LocalAPIClientError.notRunning }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(discovery.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (responseData, response): (Data, URLResponse)
        do {
            (responseData, response) = try await session.data(for: request)
        } catch {
            throw LocalAPIClientError.notRunning
        }
        guard let http = response as? HTTPURLResponse else { throw LocalAPIClientError.invalidResponse }
        switch http.statusCode {
        case 200: return responseData
        case 401: throw LocalAPIClientError.unauthorized
        default:
            throw LocalAPIClientError.server(
                status: http.statusCode, message: Self.message(in: responseData) ?? "Glint returned error \(http.statusCode).")
        }
    }

    static func message(in data: Data) -> String? {
        (try? JSONValue.parse(data))?["error"]?["message"]?.stringValue
    }
}

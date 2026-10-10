import Foundation

/// The license server API. Only buying, activating and deactivating need it; search never does.
public protocol ActivationService: Sendable {
    /// Registers `installID` against `key` and returns a signed activation token.
    func activate(key: String, installID: String) async throws -> String
    /// Frees the seat held by this install.
    func deactivate(activationToken: String, installID: String) async throws
    /// Returns `true` when the license behind `activationToken` has been revoked.
    func isRevoked(activationToken: String) async throws -> Bool
}

/// JSON-over-HTTPS client for the license server.
///
/// - `POST /v1/activate` `{"key", "install_id"}` → `200 {"activation"}`, `409` seat limit,
///   `410` revoked, `400`/`404`/`422` invalid key.
/// - `POST /v1/deactivate` `{"activation", "install_id"}` → `200`/`204`.
/// - `GET /v1/validate?activation=…` → `200 {"revoked": Bool}`.
public struct HTTPActivationService: ActivationService {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func activate(key: String, installID: String) async throws -> String {
        struct Body: Encodable {
            let key: String
            let install_id: String  // swiftlint:disable:this identifier_name
        }
        struct Response: Decodable { let activation: String }
        let data = try await send(path: "v1/activate", body: Body(key: key, install_id: installID))
        do {
            return try JSONDecoder().decode(Response.self, from: data).activation
        } catch {
            throw LicenseError.server(status: 200)
        }
    }

    public func deactivate(activationToken: String, installID: String) async throws {
        struct Body: Encodable {
            let activation: String
            let install_id: String  // swiftlint:disable:this identifier_name
        }
        _ = try await send(path: "v1/deactivate", body: Body(activation: activationToken, install_id: installID))
    }

    public func isRevoked(activationToken: String) async throws -> Bool {
        struct Response: Decodable { let revoked: Bool }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/validate"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "activation", value: activationToken)]
        guard let url = components?.url else { throw LicenseError.invalidKey }
        let data = try await perform(URLRequest(url: url))
        do {
            return try JSONDecoder().decode(Response.self, from: data).revoked
        } catch {
            throw LicenseError.server(status: 200)
        }
    }

    private func send(path: String, body: some Encodable) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 15
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LicenseError.network
        }
        guard let http = response as? HTTPURLResponse else { throw LicenseError.server(status: 0) }
        switch http.statusCode {
        case 200..<300: return data
        case 400, 404, 422: throw LicenseError.invalidKey
        case 409: throw LicenseError.seatLimitReached
        case 410: throw LicenseError.revoked
        default: throw LicenseError.server(status: http.statusCode)
        }
    }
}

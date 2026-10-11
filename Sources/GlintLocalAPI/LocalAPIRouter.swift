import Foundation
import GlintCore
import GlintSearch

/// Turns authenticated requests into search-engine calls. Pure request → response, so it is
/// tested without sockets. Logs only routes and status codes, never queries or paths.
public struct LocalAPIRouter: Sendable {
    public let engine: SearchEngine
    public let indexing: any IndexingService
    public let features: FeatureGateBox
    public let token: String
    public static let defaultLimit = 20
    public static let maxLimit = 100
    public static let maxQueryLength = 1_000

    public init(engine: SearchEngine, indexing: any IndexingService, features: FeatureGateBox, token: String) {
        self.engine = engine
        self.indexing = indexing
        self.features = features
        self.token = token
    }

    /// Handles one request that arrived on `port` (used to reject DNS-rebinding hosts).
    public func handle(_ request: HTTPRequest, port: UInt16) async -> HTTPResponse {
        if let rejection = guardRequest(request, port: port) { return rejection }
        let route = "\(request.method) \(request.path)"
        let response: HTTPResponse
        switch route {
        case "GET /v1/status":
            response = Self.json(StatusDTO(await indexing.currentStatus()))
        case "GET /v1/sources":
            do {
                response = Self.json(SourcesDTO(sources: try await indexing.sources().map(SourceDTO.init)))
            } catch {
                response = Self.error(500, "internal", "Glint couldn’t list its folders.")
            }
        case "POST /v1/search":
            response = await search(request)
        case "POST /v1/similar":
            response = await similar(request)
        default:
            let known = ["/v1/status", "/v1/sources", "/v1/search", "/v1/similar"]
            response =
                known.contains(request.path)
                ? Self.error(
                    405, "method_not_allowed",
                    "Use \(request.path.hasSuffix("search") || request.path.hasSuffix("similar") ? "POST" : "GET") for \(request.path).")
                : Self.error(404, "not_found", "Unknown endpoint. See GET /v1/status, GET /v1/sources, POST /v1/search, POST /v1/similar.")
        }
        let logged = Self.loggedRoute(request.path)
        Log.app.info("Local API \(request.method, privacy: .public) \(logged, privacy: .public) → \(response.status, privacy: .public)")
        return response
    }

    // MARK: Guards

    private func guardRequest(_ request: HTTPRequest, port: UInt16) -> HTTPResponse? {
        // Browsers send Origin; local tools don't. Refusing it blocks web pages from using the API.
        if request.headers["origin"] != nil {
            return Self.error(403, "forbidden", "Browser requests are not allowed.")
        }
        let allowedHosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
        guard let host = request.headers["host"]?.lowercased(), allowedHosts.contains(host) else {
            return Self.error(403, "forbidden", "Requests must be addressed to 127.0.0.1:\(port).")
        }
        guard let authorization = request.headers["authorization"], authorization.hasPrefix("Bearer "),
            Self.constantTimeEqual(String(authorization.dropFirst("Bearer ".count)), token)
        else {
            return Self.error(
                401, "unauthorized", "Missing or wrong bearer token. Read it from ~/Library/Application Support/Glint/api.json.")
        }
        guard features.current.allows(.localAPI) else {
            return Self.error(402, "pro_required", "The local API is part of Glint Pro. Upgrade in Glint › Settings › License.")
        }
        if request.method == "POST", let type = request.headers["content-type"], !type.lowercased().hasPrefix("application/json") {
            return Self.error(415, "unsupported_media_type", "Send JSON with Content-Type: application/json.")
        }
        return nil
    }

    // MARK: Endpoints

    private func search(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = try? JSONDecoder().decode(SearchRequestBody.self, from: request.body) else {
            return Self.error(400, "invalid_json", "Body must be JSON like {\"query\": \"beach sunset\"}.")
        }
        let text = body.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return Self.error(400, "invalid_query", "query must not be empty.") }
        guard text.count <= Self.maxQueryLength else {
            return Self.error(400, "invalid_query", "query must be at most \(Self.maxQueryLength) characters.")
        }
        var filter = SearchFilter()
        for name in body.kinds ?? [] {
            guard let kind = MediaKind(rawValue: name.lowercased()) else {
                return Self.error(400, "invalid_kind", "Unknown kind \(name). Use image, video, audio, pdf or document.")
            }
            filter.kinds.insert(kind)
        }
        filter.folders = (body.folders ?? []).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if let raw = body.modifiedAfter {
            guard let date = Self.parseDate(raw) else {
                return Self.error(400, "invalid_date", "modifiedAfter must be an ISO 8601 date, e.g. 2026-01-31 or 2026-01-31T09:00:00Z.")
            }
            filter.modifiedAfter = date
        }
        guard let limit = Self.limit(body.limit) else { return Self.limitError }
        do {
            let results = try await engine.mergedResults(for: SearchQuery(text: text, filter: filter))
            return Self.json(ResultsDTO(results: results.items.prefix(limit).map(ResultDTO.init)))
        } catch {
            return Self.engineError(error)
        }
    }

    private func similar(_ request: HTTPRequest) async -> HTTPResponse {
        guard features.current.allows(.findSimilar) else {
            return Self.error(402, "pro_required", "Find similar is part of Glint Pro.")
        }
        guard let body = try? JSONDecoder().decode(SimilarRequestBody.self, from: request.body) else {
            return Self.error(400, "invalid_json", "Body must be JSON like {\"path\": \"/Users/me/Pictures/beach.jpg\"}.")
        }
        guard body.path.hasPrefix("/") else { return Self.error(400, "invalid_path", "path must be absolute.") }
        let url = URL(fileURLWithPath: body.path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Self.error(404, "file_not_found", "No file at that path.")
        }
        guard let limit = Self.limit(body.limit) else { return Self.limitError }
        do {
            let results = try await engine.similar(toFileAt: url)
            return Self.json(ResultsDTO(results: results.items.prefix(limit).map(ResultDTO.init)))
        } catch {
            return Self.engineError(error)
        }
    }

    // MARK: Helpers

    static func limit(_ requested: Int?) -> Int? {
        guard let requested else { return defaultLimit }
        return (1...maxLimit).contains(requested) ? requested : nil
    }

    static var limitError: HTTPResponse {
        error(400, "invalid_limit", "limit must be between 1 and \(maxLimit).")
    }

    static func engineError(_ error: any Error) -> HTTPResponse {
        if let error = error as? SearchError {
            switch error {
            case .encoderUnavailable: return Self.error(503, "model_unavailable", "The search model is still loading. Try again shortly.")
            case .noExample: return Self.error(422, "no_example", "Glint couldn’t read anything to compare in that file.")
            }
        }
        if error.glintCategory == .unsupported { return Self.error(422, "unsupported_file", "Glint can’t read this kind of file.") }
        return Self.error(500, "internal", "The search failed.")
    }

    static func parseDate(_ raw: String) -> Date? {
        let full = ISO8601DateFormatter()
        if let date = full.date(from: raw) { return date }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: raw) { return date }
        full.formatOptions = [.withFullDate]
        return full.date(from: raw)
    }

    static func json(_ value: some Encodable, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: body)
    }

    static func error(_ status: Int, _ code: String, _ message: String) -> HTTPResponse {
        json(ErrorDTO(code: code, message: message), status: status)
    }

    /// The route for logs: known endpoints verbatim, anything else redacted.
    static func loggedRoute(_ path: String) -> String {
        ["/v1/status", "/v1/sources", "/v1/search", "/v1/similar"].contains(path) ? path : "<other>"
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }
}

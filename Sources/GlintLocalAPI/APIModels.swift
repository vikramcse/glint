import Foundation
import GlintCore
import GlintSearch

/// `POST /v1/search` body.
public struct SearchRequestBody: Codable, Sendable, Hashable {
    public var query: String
    /// Media kinds to include: `image`, `video`, `audio`, `pdf`, `document`. Omit for all.
    public var kinds: [String]?
    /// Maximum results, 1–100 (default 20).
    public var limit: Int?
    /// Absolute folder paths to search within.
    public var folders: [String]?
    /// ISO 8601 date; only files modified at or after it.
    public var modifiedAfter: String?

    public init(query: String, kinds: [String]? = nil, limit: Int? = nil, folders: [String]? = nil, modifiedAfter: String? = nil) {
        self.query = query
        self.kinds = kinds
        self.limit = limit
        self.folders = folders
        self.modifiedAfter = modifiedAfter
    }
}

/// `POST /v1/similar` body.
public struct SimilarRequestBody: Codable, Sendable, Hashable {
    /// Absolute path of the example file.
    public var path: String
    public var limit: Int?

    public init(path: String, limit: Int? = nil) {
        self.path = path
        self.limit = limit
    }
}

/// One result. `page` is 1-based; `start`/`end` are seconds into audio or video.
public struct ResultDTO: Codable, Sendable, Hashable {
    public var path: String
    public var name: String
    public var kind: String
    public var score: Double
    public var modified: String
    public var page: Int?
    public var start: Double?
    public var end: Double?
    public var snippet: String?
    /// False when the file matched by name before its contents were indexed.
    public var indexed: Bool

    init(_ result: SearchResult) {
        path = result.file.path
        name = result.file.name
        kind = result.file.kind.rawValue
        score = (result.score * 10_000).rounded() / 10_000
        modified = ISO8601DateFormatter().string(from: result.file.modified)
        switch result.match.locator {
        case .page(let index): page = index + 1
        case .time(let from, let to):
            start = from
            end = to
        case .whole, .text: break
        }
        snippet = result.match.snippet?.text
        indexed = result.file.isIndexed
    }
}

public struct ResultsDTO: Codable, Sendable, Hashable {
    public var results: [ResultDTO]
}

public struct StatusDTO: Codable, Sendable, Hashable {
    /// `idle`, `scanning`, `indexing` or `paused`.
    public var phase: String
    /// Why indexing is paused: `user`, `lowBattery`, `lowPowerMode`, `thermal`.
    public var pauseReason: String?
    public var indexed: [String: Int]
    public var totalIndexed: Int
    public var pending: Int
    public var failed: Int
    public var sources: Int

    init(_ status: IndexStatus) {
        switch status.phase {
        case .idle: phase = "idle"
        case .scanning: phase = "scanning"
        case .indexing: phase = "indexing"
        case .paused(let reason):
            phase = "paused"
            pauseReason = reason.rawValue
        }
        indexed = Dictionary(uniqueKeysWithValues: status.indexed.map { ($0.key.rawValue, $0.value) })
        totalIndexed = status.totalIndexed
        pending = status.pending
        failed = status.failed
        sources = status.sourceCount
    }
}

public struct SourceDTO: Codable, Sendable, Hashable {
    public var path: String
    public var name: String
    public var accessible: Bool
    public var external: Bool
    public var network: Bool
    public var items: Int
    public var indexed: Int
    public var pending: Int
    public var failed: Int
    public var complete: Bool

    init(_ source: SourceInfo) {
        path = source.path
        name = source.displayName
        accessible = source.isAccessible
        external = source.isExternalVolume
        network = source.isNetworkVolume
        items = source.itemCount
        indexed = source.indexed
        pending = source.pending
        failed = source.failed
        complete = source.isComplete
    }
}

public struct SourcesDTO: Codable, Sendable, Hashable {
    public var sources: [SourceDTO]
}

/// Every error body: `{"error": {"code": "...", "message": "..."}}`.
public struct ErrorDTO: Codable, Sendable, Hashable {
    public struct Detail: Codable, Sendable, Hashable {
        public var code: String
        public var message: String
    }

    public var error: Detail

    public init(code: String, message: String) {
        error = Detail(code: code, message: message)
    }
}

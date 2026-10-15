import Foundation
import GlintCore
import GlintStore

/// A search request: free text plus a filter.
public struct SearchQuery: Sendable, Hashable {
    public var text: String
    public var filter: SearchFilter
    /// Match the text against file names only (anywhere in the name), skipping contents and meaning.
    public var namesOnly: Bool

    public init(text: String, filter: SearchFilter = .none, namesOnly: Bool = false) {
        self.text = text
        self.filter = filter
        self.namesOnly = namesOnly
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Which phase produced a result list.
public enum SearchPhase: Sendable, Hashable {
    /// Keyword and file-name matches, rendered on the keystroke.
    case keyword
    /// Keyword and semantic matches fused, rendered when the query embedding returns.
    case merged
}

/// The file behind a result.
public struct FileSummary: Sendable, Hashable {
    public var id: FileID
    public var name: String
    public var path: String
    public var kind: MediaKind
    public var modified: Date
    public var size: Int64
    public var duration: Double?
    public var waveform: [Float]?
    public var isIndexed: Bool

    public var url: URL { URL(fileURLWithPath: path) }
    public var folder: String { (path as NSString).deletingLastPathComponent }

    public init(
        id: FileID, name: String, path: String, kind: MediaKind, modified: Date, size: Int64,
        duration: Double? = nil, waveform: [Float]? = nil, isIndexed: Bool = true
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.modified = modified
        self.size = size
        self.duration = duration
        self.waveform = waveform
        self.isIndexed = isIndexed
    }

    init(_ record: FileRecord) {
        id = record.id
        name = record.name
        path = record.path
        kind = record.kind
        modified = record.modified
        size = record.size
        duration = record.duration
        waveform = record.waveform
        isIndexed = record.status == .indexed
    }
}

/// The part of a file that matched.
public struct MatchDetail: Sendable, Hashable {
    public var chunkID: ChunkID?
    public var locator: ChunkLocator
    public var snippet: Snippet?
    /// Precomputed thumbnail (photo, page render, keyframe), if any.
    public var thumbnailURL: URL?

    public init(chunkID: ChunkID?, locator: ChunkLocator, snippet: Snippet?, thumbnailURL: URL?) {
        self.chunkID = chunkID
        self.locator = locator
        self.snippet = snippet
        self.thumbnailURL = thumbnailURL
    }
}

/// One file in the results, with its best match.
public struct SearchResult: Sendable, Hashable, Identifiable {
    public var file: FileSummary
    public var match: MatchDetail
    public var score: Double
    public var sources: MatchSources

    public init(file: FileSummary, match: MatchDetail, score: Double, sources: MatchSources) {
        self.file = file
        self.match = match
        self.score = score
        self.sources = sources
    }

    public var id: FileID { file.id }
}

/// A result list for one query and phase.
public struct SearchResults: Sendable, Hashable {
    public var query: SearchQuery
    public var phase: SearchPhase
    public var items: [SearchResult]
    /// Milliseconds spent in the engine for this phase.
    public var elapsedMilliseconds: Double

    public init(query: SearchQuery, phase: SearchPhase, items: [SearchResult], elapsedMilliseconds: Double) {
        self.query = query
        self.phase = phase
        self.items = items
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    public static func empty(_ query: SearchQuery, phase: SearchPhase = .merged) -> SearchResults {
        SearchResults(query: query, phase: phase, items: [], elapsedMilliseconds: 0)
    }
}

/// Keeps the row under the cursor in place when a new result list replaces the old one,
/// so semantic results can merge in without moving what the user is looking at.
public enum ResultStabilizer {
    public static func stabilize<ID: Hashable>(previous: [ID], next: [ID], pinned: ID?) -> [ID] {
        guard let pinned, let oldIndex = previous.firstIndex(of: pinned), let newIndex = next.firstIndex(of: pinned),
            oldIndex != newIndex
        else { return next }
        var result = next
        result.remove(at: newIndex)
        result.insert(pinned, at: min(oldIndex, result.count))
        return result
    }

    public static func stabilize(previous: [SearchResult], next: [SearchResult], pinned: FileID?) -> [SearchResult] {
        let byID = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return stabilize(previous: previous.map(\.id), next: next.map(\.id), pinned: pinned).compactMap { byID[$0] }
    }
}

import Foundation
import GlintCore
import GlintSearch

/// Search results as JSON, for rendering real result rows outside the app (the README demo
/// video renders them with `GlintUI`'s `ResultRow`; see `scripts/demo-video`).
struct ExportedQuery: Codable {
    var query: String
    /// What the panel shows on the keystroke, before the query is embedded.
    var keyword: [ExportedResult]
    /// What it shows once semantic results merge in.
    var merged: [ExportedResult]
}

struct ExportedResult: Codable {
    var name: String
    var path: String
    var kind: MediaKind
    var modified: Date
    var size: Int64
    var duration: Double?
    var waveform: [Float]?
    var locator: ChunkLocator
    var snippet: String?
    /// Highlighted ranges in `snippet`, as character offset and length.
    var highlights: [[Int]]
    var thumbnail: String?
    var score: Double
    var sources: [String]

    init(_ result: SearchResult) {
        name = result.file.name
        path = result.file.path
        kind = result.file.kind
        modified = result.file.modified
        size = result.file.size
        duration = result.file.duration
        waveform = result.file.waveform
        locator = result.match.locator
        thumbnail = result.match.thumbnailURL?.path
        score = result.score
        sources = [(MatchSources.semantic, "semantic"), (.keyword, "keyword"), (.name, "name")]
            .filter { result.sources.contains($0.0) }.map(\.1)
        if let snippet = result.match.snippet {
            self.snippet = snippet.text
            highlights = snippet.highlights.map { range in
                [
                    snippet.text.distance(from: snippet.text.startIndex, to: range.lowerBound),
                    snippet.text.distance(from: range.lowerBound, to: range.upperBound),
                ]
            }
        } else {
            highlights = []
        }
    }
}

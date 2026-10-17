import AppKit
import GlintCore
import GlintSearch
import SwiftUI
import Testing

@testable import GlintUI

/// Renders real result rows for the README demo video (`scripts/demo-video`).
/// Does nothing unless `GLINT_DEMO_RESULTS` (JSON from `glint-eval query --json`) and
/// `GLINT_DEMO_OUT` are set.
@MainActor
@Suite("Demo frames")
struct DemoRenderTests {
    private struct Exported: Decodable {
        var query: String
        var merged: [Row]
    }

    private struct Row: Decodable {
        var name: String
        var path: String
        var kind: MediaKind
        var modified: Date
        var size: Int64
        var duration: Double?
        var waveform: [Float]?
        var locator: ChunkLocator
        var snippet: String?
        var highlights: [[Int]]
        var thumbnail: String?
        var score: Double
    }

    @Test func rendersDemoFrames() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["GLINT_DEMO_RESULTS"], let output = environment["GLINT_DEMO_OUT"] else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let queries = try decoder.decode([Exported].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (index, query) in queries.enumerated() {
            let results = query.merged.enumerated().map { offset, row in Self.result(row, id: index * 100 + offset) }
            for result in results {
                if let url = result.match.thumbnailURL { _ = await ThumbnailCache.shared.load(url) }
            }
            let section = ResultSection(kind: .all, results: results)
            let view = VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                ForEach(Array(results.enumerated()), id: \.offset) { offset, result in
                    ResultRow(result: result, isSelected: offset == 0)
                        .padding(.horizontal, 8)
                        .background {
                            if offset == 0 { RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.22)) }
                        }
                }
            }
            .padding(8)
            .frame(width: 720, alignment: .leading)
            .environment(\.colorScheme, .dark)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("rows-\(index).png"))
        }
    }

    private static func result(_ row: Row, id: Int) -> SearchResult {
        var highlights: [Range<String.Index>] = []
        if let text = row.snippet {
            for pair in row.highlights where pair.count == 2 {
                let start = text.index(text.startIndex, offsetBy: pair[0])
                highlights.append(start..<text.index(start, offsetBy: pair[1]))
            }
        }
        return SearchResult(
            file: FileSummary(
                id: FileID(Int64(id)), name: row.name, path: row.path, kind: row.kind, modified: row.modified, size: row.size,
                duration: row.duration, waveform: row.waveform),
            match: MatchDetail(
                chunkID: nil, locator: row.locator, snippet: row.snippet.map { Snippet(text: $0, highlights: highlights) },
                thumbnailURL: row.thumbnail.map { URL(fileURLWithPath: $0) }),
            score: row.score, sources: [.semantic])
    }
}

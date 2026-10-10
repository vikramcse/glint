import Foundation

/// A short excerpt of chunk text around the first query term, with term ranges to highlight.
public struct Snippet: Sendable, Hashable {
    public var text: String
    /// Ranges in `text` that match query terms.
    public var highlights: [Range<String.Index>]

    public init(text: String, highlights: [Range<String.Index>]) {
        self.text = text
        self.highlights = highlights
    }

    /// Builds a snippet of at most about `maxLength` characters.
    public static func make(from source: String, terms: [String], maxLength: Int = 180) -> Snippet {
        let collapsed = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return Snippet(text: "", highlights: []) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        let firstMatch = terms.lazy.compactMap { collapsed.range(of: $0, options: options) }
            .min { $0.lowerBound < $1.lowerBound }
        var start = collapsed.startIndex
        if let firstMatch {
            start = collapsed.index(firstMatch.lowerBound, offsetBy: -maxLength / 3, limitedBy: collapsed.startIndex)
                ?? collapsed.startIndex
            if start > collapsed.startIndex, let space = collapsed[start...].firstIndex(of: " "), space < firstMatch.lowerBound {
                start = collapsed.index(after: space)
            }
        }
        var end = collapsed.index(start, offsetBy: maxLength, limitedBy: collapsed.endIndex) ?? collapsed.endIndex
        if end < collapsed.endIndex, let space = collapsed[start..<end].lastIndex(of: " ") { end = space }

        var text = String(collapsed[start..<end])
        if start > collapsed.startIndex { text = "…" + text }
        if end < collapsed.endIndex { text += "…" }

        var highlights: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var searchStart = text.startIndex
            while let range = text.range(of: term, options: options, range: searchStart..<text.endIndex) {
                highlights.append(range)
                searchStart = range.upperBound
            }
        }
        highlights.sort { $0.lowerBound < $1.lowerBound }
        return Snippet(text: text, highlights: highlights)
    }
}

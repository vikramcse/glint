import Foundation

/// Builds safe FTS5 match expressions from what the user typed.
public struct FTSQuery: Sendable, Hashable {
    /// Search terms, lowercased, stop words removed (unless only stop words were typed).
    public let terms: [String]
    /// Whether the last term should match as a prefix (the user is still typing it).
    public let prefixLast: Bool

    /// - Parameter allowsPrefix: `false` matches whole words only, for when the user has
    ///   stopped typing ("car" should not find "carefully").
    public init(_ text: String, allowsPrefix: Bool = true) {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let meaningful = words.filter { !FTSQuery.stopWords.contains($0) }
        terms = meaningful.isEmpty ? words : meaningful
        let endsInWord = text.unicodeScalars.last.map(CharacterSet.alphanumerics.contains) ?? false
        // A one-letter prefix matches too much to be useful or fast.
        prefixLast = allowsPrefix && endsInWord && (terms.last?.count ?? 0) >= 2
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// Every term must match (`"blue" "mug"*`).
    public var all: String? { expression(joinedBy: " ") }

    /// Any term may match; BM25 ranks files with more terms higher.
    public var any: String? { expression(joinedBy: " OR ") }

    private func expression(joinedBy separator: String) -> String? {
        guard !terms.isEmpty else { return nil }
        return terms.enumerated().map { index, term in
            let quoted = "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
            return index == terms.count - 1 && prefixLast ? quoted + "*" : quoted
        }.joined(separator: separator)
    }

    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "in", "on", "at", "to", "for", "with", "from", "by", "is", "was",
        "it", "that", "this", "my", "me", "i", "where", "when", "what", "which", "show", "find", "about",
    ]
}

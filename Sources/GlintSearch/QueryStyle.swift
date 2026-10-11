import Foundation

/// How literally a query should be read, to lean the fusion towards keywords or meaning.
///
/// "IMG_4821", "invoice 2024-0413" or a quoted phrase name something exact: the words matter
/// more than what they mean. "that photo of my dog at the lake" describes something: the
/// meaning matters more than any single word.
public enum QueryStyle: Sendable, Hashable {
    case literal
    case balanced
    case descriptive

    /// Literal queries are short; a long sentence with a number in it is still a description.
    static let literalMaximumWords = 3
    /// Descriptions have at least this many words.
    static let descriptiveMinimumWords = 5

    public init(_ text: String) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count <= Self.literalMaximumWords, text.contains("\"") || words.contains(where: Self.looksLikeIdentifier) {
            self = .literal
        } else if words.count >= Self.descriptiveMinimumWords {
            self = .descriptive
        } else {
            self = .balanced
        }
    }

    /// Multipliers for the ranker's semantic and keyword (and file name) weights.
    public var weights: (semantic: Double, keyword: Double) {
        switch self {
        case .literal: (0.6, 1.5)
        case .balanced: (1, 1)
        case .descriptive: (1, 0.8)
        }
    }

    /// File names, codes and numbers: "IMG_4821", "report.pdf", "2024-0413", "v2", "iPhone".
    static func looksLikeIdentifier(_ word: String) -> Bool {
        let letters = word.contains(where: \.isLetter)
        let digits = word.filter(\.isNumber).count
        if word.contains("_") { return true }
        if letters && digits > 0 { return true }
        if digits >= 3 { return true }
        // A dot between letters or digits, as in a file name ("report.pdf"), not a full stop.
        if let dot = word.firstIndex(of: "."), dot != word.startIndex, word.index(after: dot) != word.endIndex,
            word[word.index(after: dot)].isLetter || word[word.index(after: dot)].isNumber
        {
            return true
        }
        // An upper-case letter after a lower-case one ("iPhone", "GlintSearch").
        return zip(word, word.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
    }
}

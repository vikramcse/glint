import Foundation

/// Splits text into overlapping chunks of roughly `maxTokens` tokens without splitting words.
///
/// Tokens are approximated from whitespace-separated words (`tokensPerWord`, 1.3 by default,
/// is typical for English with a SentencePiece vocabulary). Offsets are `Character` offsets
/// into the input, matching `ChunkLocator.text(start:end:)`.
public struct TextChunker: Sendable, Hashable {
    /// A chunk of text and where it sits in the source.
    public struct Piece: Sendable, Hashable {
        public var text: String
        /// Character offset of the first character.
        public var start: Int
        /// Character offset one past the last character.
        public var end: Int

        public init(text: String, start: Int, end: Int) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    public var maxTokens: Int
    public var overlapTokens: Int
    public var tokensPerWord: Double

    public init(maxTokens: Int = 512, overlapTokens: Int = 64, tokensPerWord: Double = 1.3) {
        self.maxTokens = max(1, maxTokens)
        self.overlapTokens = max(0, overlapTokens)
        self.tokensPerWord = max(0.01, tokensPerWord)
    }

    /// Words that fit in one chunk.
    public var wordsPerChunk: Int { max(1, Int(Double(maxTokens) / tokensPerWord)) }

    /// Words repeated at the start of the next chunk. Always less than `wordsPerChunk`.
    public var overlapWords: Int { min(wordsPerChunk - 1, Int(Double(overlapTokens) / tokensPerWord)) }

    /// Splits `text`. Returns no pieces for empty or whitespace-only text.
    public func chunk(_ text: String) -> [Piece] {
        let words = Self.wordRanges(in: text)
        guard !words.isEmpty else { return [] }

        var pieces: [Piece] = []
        var first = 0
        while first < words.count {
            let last = min(first + wordsPerChunk, words.count) - 1
            let startWord = words[first]
            let endWord = words[last]
            pieces.append(
                Piece(
                    text: String(text[startWord.range.lowerBound..<endWord.range.upperBound]),
                    start: startWord.start,
                    end: endWord.end
                )
            )
            if last == words.count - 1 { break }
            first = max(first + 1, last + 1 - overlapWords)
        }
        return pieces
    }

    private struct Word {
        var range: Range<String.Index>
        var start: Int
        var end: Int
    }

    private static func wordRanges(in text: String) -> [Word] {
        var words: [Word] = []
        var offset = 0
        var wordStart: (index: String.Index, offset: Int)?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                if let start = wordStart {
                    words.append(Word(range: start.index..<index, start: start.offset, end: offset))
                    wordStart = nil
                }
            } else if wordStart == nil {
                wordStart = (index, offset)
            }
            index = text.index(after: index)
            offset += 1
        }
        if let start = wordStart {
            words.append(Word(range: start.index..<text.endIndex, start: start.offset, end: offset))
        }
        return words
    }
}

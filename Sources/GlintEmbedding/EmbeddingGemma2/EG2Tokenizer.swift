import Foundation

/// EmbeddingGemma 2's tokenizer (`tokenizer.json`), kept compact.
///
/// The pipeline is Gemma's: split out special tokens, replace spaces with `▁`, then BPE over
/// each section (no pre-tokenization), lowest merge rank first and leftmost on ties, with
/// byte fallback (`<0xXX>`) for characters outside the vocabulary.
///
/// Tokens are looked up by their exact UTF-8 bytes: Swift `String` equality is canonical, and
/// 434 Gemma tokens differ only in Unicode normalization, so a `[String: Int]` would merge them.
/// Merges are stored as token-id pairs, which keeps the 262k-token vocabulary and 515k merges
/// far smaller than swift-transformers' string-keyed tables (~150 MB).
/// Token ids match Hugging Face's Rust tokenizer on every text in `EG2TokenizerParityTests`.
struct EG2Tokenizer: Sendable {
    private let vocabulary: VocabularyTable
    /// `left << 32 | right` → `rank << 32 | merged`.
    private let merges: [UInt64: UInt64]
    /// Ids of `<0x00>`…`<0xFF>`.
    private let byteTokens: [Int32]
    /// Special tokens, longest first so a longer token wins over its prefix.
    private let specialTokens: [(content: [UInt8], id: Int32)]

    enum LoadError: Error {
        case malformed(String)
    }

    init(directory: URL) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("tokenizer.json"))
        // Foundation's parsers can't read this file exactly: JSONSerialization strips a leading
        // U+FEFF from strings, and dictionary-backed decoding merges canonically equal keys.
        guard case .object(let root) = try ExactJSON.parse(data),
            case .object(let model)? = root.first(where: { $0.key == "model" })?.value,
            case .object(let vocab)? = model.first(where: { $0.key == "vocab" })?.value,
            case .array(let mergeList)? = model.first(where: { $0.key == "merges" })?.value
        else { throw LoadError.malformed("model") }
        guard case .string("BPE")? = model.first(where: { $0.key == "type" })?.value else { throw LoadError.malformed("not BPE") }

        let vocabulary = VocabularyTable(
            try vocab.map { key, value in
                guard case .number(let id) = value else { throw LoadError.malformed("vocab") }
                return (Array(key.utf8), Int32(id))
            })

        var merges: [UInt64: UInt64] = [:]
        merges.reserveCapacity(mergeList.count)
        for (rank, item) in mergeList.enumerated() {
            guard case .array(let pair) = item, pair.count == 2, case .string(let first) = pair[0], case .string(let second) = pair[1],
                let left = vocabulary[Array(first.utf8)], let right = vocabulary[Array(second.utf8)],
                let merged = vocabulary[Array(first.utf8) + Array(second.utf8)]
            else { throw LoadError.malformed("merge \(rank)") }
            let key = UInt64(UInt32(left)) << 32 | UInt64(UInt32(right))
            // Duplicate merges keep the first (lowest) rank, as the reference does.
            if merges[key] == nil { merges[key] = UInt64(rank) << 32 | UInt64(UInt32(merged)) }
        }

        var specialTokens: [(content: [UInt8], id: Int32)] = []
        if case .array(let added)? = root.first(where: { $0.key == "added_tokens" })?.value {
            for case .object(let token) in added {
                guard case .string(let content)? = token.first(where: { $0.key == "content" })?.value,
                    case .number(let id)? = token.first(where: { $0.key == "id" })?.value
                else { continue }
                specialTokens.append((Array(content.utf8), Int32(id)))
            }
        }
        specialTokens.sort { $0.content.count > $1.content.count }
        self.vocabulary = vocabulary
        self.merges = merges
        self.specialTokens = specialTokens
        byteTokens = try (0..<256).map { byte in
            guard let id = vocabulary[Array(String(format: "<0x%02X>", byte).utf8)] else { throw LoadError.malformed("byte \(byte)") }
            return id
        }
    }

    /// Token ids for `text`, without `<bos>`/`<eos>`.
    func encode(_ text: String) -> [Int32] {
        var ids: [Int32] = []
        ids.reserveCapacity(text.utf8.count / 3 + 1)
        for section in sections(of: text) {
            switch section {
            case .special(let id): ids.append(id)
            case .text(let piece):
                // Per scalar, not per grapheme: a space followed by a combining mark is one
                // grapheme, and `replacingOccurrences` would leave that space unreplaced.
                var normalized = String.UnicodeScalarView()
                normalized.append(contentsOf: piece.unicodeScalars.lazy.map { $0 == " " ? "\u{2581}" : $0 })
                bpe(String(normalized), into: &ids)
            }
        }
        return ids
    }

    private enum Section {
        case text(String)
        case special(Int32)
    }

    /// Splits out special tokens (leftmost match, longest token at that position).
    private func sections(of text: String) -> [Section] {
        let bytes = Array(text.utf8)
        // Every special token starts with "<"; skip the scan when there is none.
        guard bytes.contains(UInt8(ascii: "<")) else { return text.isEmpty ? [] : [.text(text)] }
        var result: [Section] = []
        var start = 0
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "<"),
                let match = specialTokens.first(where: { token in
                    index + token.content.count <= bytes.count && bytes[index..<(index + token.content.count)].elementsEqual(token.content)
                })
            {
                if start < index { result.append(.text(String(lossyUTF8: bytes[start..<index]))) }
                result.append(.special(match.id))
                index += match.content.count
                start = index
            } else {
                index += 1
            }
        }
        if start < bytes.count { result.append(.text(String(lossyUTF8: bytes[start...]))) }
        return result
    }

    /// Byte-pair encodes one section: symbols start as single characters (Unicode scalars) and
    /// the lowest-ranked adjacent pair merges first, leftmost on ties. Characters outside the
    /// vocabulary never merge and become their UTF-8 bytes.
    private func bpe(_ text: String, into ids: inout [Int32]) {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return }
        // -1 marks a character outside the vocabulary.
        var symbols = scalars.map { vocabulary[Array(String($0).utf8)] ?? -1 }
        let count = symbols.count
        var next = Array(1...count)
        next[count - 1] = -1
        var previous = Array(-1..<(count - 1))
        var alive = [Bool](repeating: true, count: count)

        // Min-heap of (rank << 32 | left position); stale entries are skipped when popped.
        var heap = MinHeap()
        func candidate(_ left: Int) -> (rank: UInt32, merged: Int32)? {
            let right = next[left]
            guard right != -1, symbols[left] >= 0, symbols[right] >= 0 else { return nil }
            let key = UInt64(UInt32(symbols[left])) << 32 | UInt64(UInt32(symbols[right]))
            guard let value = merges[key] else { return nil }
            return (UInt32(value >> 32), Int32(truncatingIfNeeded: value & 0xFFFF_FFFF))
        }
        func enqueue(_ left: Int) {
            if let found = candidate(left) { heap.push(UInt64(found.rank) << 32 | UInt64(left)) }
        }
        for left in 0..<(count - 1) { enqueue(left) }

        while let top = heap.pop() {
            let left = Int(top & 0xFFFF_FFFF)
            let rank = UInt32(top >> 32)
            guard alive[left], let found = candidate(left), found.rank == rank else { continue }
            let right = next[left]
            symbols[left] = found.merged
            alive[right] = false
            next[left] = next[right]
            if next[left] != -1 { previous[next[left]] = left }
            if previous[left] != -1 { enqueue(previous[left]) }
            enqueue(left)
        }
        append(symbols, linkedBy: next, of: scalars, to: &ids)
    }

    /// Appends the merged symbols in order; characters outside the vocabulary become their bytes.
    private func append(_ symbols: [Int32], linkedBy next: [Int], of scalars: [Unicode.Scalar], to ids: inout [Int32]) {
        var cursor = 0
        while cursor != -1 {
            if symbols[cursor] >= 0 {
                ids.append(symbols[cursor])
            } else {
                for byte in String(scalars[cursor]).utf8 { ids.append(byteTokens[Int(byte)]) }
            }
            cursor = next[cursor]
        }
    }
}

/// Token id by exact UTF-8 bytes: every token's bytes in one buffer, found through an
/// open-addressing hash table of ids.
private struct VocabularyTable: Sendable {
    private let bytes: [UInt8]
    /// Start of each id's bytes in `bytes`; `offsets[id + 1]` is its end.
    private let offsets: [UInt32]
    /// Ids, or -1 for an empty slot; the size is a power of two.
    private let slots: [Int32]

    init(_ entries: [(bytes: [UInt8], id: Int32)]) {
        let count = Int(entries.map(\.id).max() ?? -1) + 1
        var lengths = [Int](repeating: 0, count: count)
        var byID = [[UInt8]](repeating: [], count: count)
        for entry in entries {
            byID[Int(entry.id)] = entry.bytes
            lengths[Int(entry.id)] = entry.bytes.count
        }
        var offsets = [UInt32](repeating: 0, count: count + 1)
        for id in 0..<count { offsets[id + 1] = offsets[id] + UInt32(lengths[id]) }
        self.offsets = offsets
        bytes = byID.flatMap { $0 }
        var size = 1
        while size < count * 2 { size <<= 1 }
        var slots = [Int32](repeating: -1, count: size)
        for entry in entries {
            var slot = Int(Self.hash(entry.bytes[...]) & UInt64(size - 1))
            while slots[slot] != -1 { slot = (slot + 1) & (size - 1) }
            slots[slot] = entry.id
        }
        self.slots = slots
    }

    subscript(token: [UInt8]) -> Int32? {
        var slot = Int(Self.hash(token[...]) & UInt64(slots.count - 1))
        while slots[slot] != -1 {
            let id = Int(slots[slot])
            let start = Int(offsets[id])
            let end = Int(offsets[id + 1])
            if end - start == token.count, bytes[start..<end].elementsEqual(token) { return Int32(id) }
            slot = (slot + 1) & (slots.count - 1)
        }
        return nil
    }

    /// FNV-1a.
    private static func hash(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }
}

/// A binary min-heap of packed keys.
private struct MinHeap {
    private var items: [UInt64] = []

    mutating func push(_ item: UInt64) {
        items.append(item)
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child] < items[parent] else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> UInt64? {
        guard let first = items.first else { return nil }
        let last = items.removeLast()
        guard !items.isEmpty else { return first }
        items[0] = last
        var parent = 0
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < items.count, items[left] < items[smallest] { smallest = left }
            if right < items.count, items[right] < items[smallest] { smallest = right }
            guard smallest != parent else { return first }
            items.swapAt(parent, smallest)
            parent = smallest
        }
    }
}

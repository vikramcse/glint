import Foundation

/// Turns raw bytes into text without trusting the file to declare its encoding.
enum TextDecoding {
    /// Decodes `data`, trying BOMs, strict UTF-8, BOM-less UTF-16, then Windows-1252 and Latin-1.
    /// Throws `ExtractionError.unsupported` for binary data.
    static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            // Lossy on purpose: the BOM settles the encoding, so stray bytes become U+FFFD.
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) { return text }
        }
        if let text = String(data: data, encoding: .utf8) {
            guard !text.contains("\u{0}") else { throw ExtractionError.unsupported }
            return text
        }
        if let encoding = bomlessUTF16Encoding(data), let text = String(data: data, encoding: encoding) {
            return text
        }
        if looksBinary(data) { throw ExtractionError.unsupported }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw ExtractionError.unsupported
    }

    /// UTF-16 without a BOM shows up as a NUL in every other byte of ASCII-heavy text.
    private static func bomlessUTF16Encoding(_ data: Data) -> String.Encoding? {
        let sample = data.prefix(4_096)
        guard sample.count >= 4 else { return nil }
        var evenZeros = 0
        var oddZeros = 0
        for (offset, byte) in sample.enumerated() where byte == 0 {
            if offset.isMultiple(of: 2) { evenZeros += 1 } else { oddZeros += 1 }
        }
        let half = sample.count / 2
        if oddZeros > half * 6 / 10, evenZeros < half / 10 { return .utf16LittleEndian }
        if evenZeros > half * 6 / 10, oddZeros < half / 10 { return .utf16BigEndian }
        return nil
    }

    private static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8_192)
        guard !sample.isEmpty else { return false }
        if sample.contains(0) { return true }
        let controls = sample.filter { $0 < 0x09 || ($0 > 0x0D && $0 < 0x20) }.count
        return controls * 10 > sample.count
    }

    /// Strips tags, scripts, styles and entities from HTML. Good enough for indexing; no WebKit.
    ///
    /// Scans rather than using lazy regexes: those rescan to the end of the file for every
    /// unclosed `<script` or `<`, which turns a crafted 20 MB file into hours of work.
    static func plainText(fromHTML html: String) -> String {
        var bytes = Array(html.utf8)
        bytes = HTMLScanner.removingBlocks(bytes, opener: "<script", closer: "</script>", wordBoundary: true)
        bytes = HTMLScanner.removingBlocks(bytes, opener: "<style", closer: "</style>", wordBoundary: true)
        bytes = HTMLScanner.removingBlocks(bytes, opener: "<!--", closer: "-->", wordBoundary: false)
        bytes = HTMLScanner.replacingTags(bytes, onlyLineBreaks: true)
        bytes = HTMLScanner.replacingTags(bytes, onlyLineBreaks: false)
        // Only whole ASCII spans were replaced, so the bytes are still valid UTF-8.
        // swiftlint:disable:next optional_data_string_conversion
        let text = decodeEntities(String(decoding: bytes, as: UTF8.self))
        return collapseWhitespace(text)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "copy": "©", "reg": "®", "rsquo": "’", "lsquo": "‘",
        "rdquo": "”", "ldquo": "“",
    ]

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&",
                let semicolon = text[index...].prefix(12).firstIndex(of: ";")
            else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let name = String(text[text.index(after: index)..<semicolon])
            if let decoded = decodeEntity(name) {
                result += decoded
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func decodeEntity(_ name: String) -> String? {
        if let named = namedEntities[name] { return named }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value: UInt32? =
            digits.lowercased().hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }

    /// Collapses runs of spaces and tabs, and runs of more than two newlines.
    static func collapseWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[ \\t\\u{00A0}\\f\\v]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ?\\n[ \\n]*\\n", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Linear-time passes over UTF-8 HTML. Every delimiter is ASCII, so byte offsets never split a
/// character. Each pass matches what its regex did:
/// `(?is)<script\b.*?</script>`, `(?is)<style\b.*?</style>`, `(?s)<!--.*?-->`,
/// `(?i)<(br|/p|/div|/li|/h[1-6]|/tr)\b[^>]*>` (to a newline), then `<[^>]+>` (to a space).
enum HTMLScanner {
    private static let space = UInt8(ascii: " ")
    private static let newline = UInt8(ascii: "\n")
    private static let less = UInt8(ascii: "<")
    private static let greater = UInt8(ascii: ">")
    private static let lineBreakTags = ["br", "/p", "/div", "/li", "/h1", "/h2", "/h3", "/h4", "/h5", "/h6", "/tr"].map { Array($0.utf8) }

    /// Replaces each `opener … closer` span (shortest, ASCII case-insensitive) with a space.
    /// An opener with no closer after it is left as text, as the regex left it.
    static func removingBlocks(_ bytes: [UInt8], opener: String, closer: String, wordBoundary: Bool) -> [UInt8] {
        let opener = Array(opener.utf8)
        let closer = Array(closer.utf8)
        var finder = ForwardFinder(bytes: bytes, needle: closer)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let bodyStart = index + opener.count
            if bytes[index] == less, matches(bytes, at: index, opener),
                !wordBoundary || bodyStart == bytes.count || !isWordByte(bytes[bodyStart]),
                let end = finder.next(from: bodyStart)
            {
                output.append(space)
                index = end + closer.count
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }

    /// Replaces tags (`<` up to the next `>`, with something between) with a space, or when
    /// `onlyLineBreaks`, just the tags that end a line, with a newline.
    static func replacingTags(_ bytes: [UInt8], onlyLineBreaks: Bool) -> [UInt8] {
        var finder = ForwardFinder(bytes: bytes, needle: [greater])
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == less, index + 1 < bytes.count, bytes[index + 1] != greater,
                !onlyLineBreaks || isLineBreakTag(bytes, at: index + 1),
                let end = finder.next(from: index + 1)
            {
                output.append(onlyLineBreaks ? newline : space)
                index = end + 1
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }

    private static func isLineBreakTag(_ bytes: [UInt8], at index: Int) -> Bool {
        lineBreakTags.contains { name in
            let end = index + name.count
            return matches(bytes, at: index, name) && (end == bytes.count || !isWordByte(bytes[end]))
        }
    }

    /// Whether `bytes` holds `needle` at `index`, ignoring ASCII case.
    static func matches(_ bytes: [UInt8], at index: Int, _ needle: [UInt8]) -> Bool {
        guard index + needle.count <= bytes.count else { return false }
        for offset in 0..<needle.count where lowercased(bytes[index + offset]) != lowercased(needle[offset]) {
            return false
        }
        return true
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte | 0x20 : byte
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        // Bytes of non-ASCII characters count as word characters, as letters would for \b.
        byte >= 0x80 || byte == UInt8(ascii: "_") || (0x30...0x39).contains(byte) || (0x61...0x7A).contains(lowercased(byte))
    }

    /// Finds the next occurrence of a needle at or after positions that only move forward, so
    /// a whole pass costs one scan of the input however many openers lack a closer.
    struct ForwardFinder {
        let bytes: [UInt8]
        let needle: [UInt8]
        /// The last match found, or `bytes.count` once no match remains.
        private var found = -1

        init(bytes: [UInt8], needle: [UInt8]) {
            self.bytes = bytes
            self.needle = needle
        }

        mutating func next(from start: Int) -> Int? {
            if found >= start { return found < bytes.count ? found : nil }
            var index = max(start, found + 1)
            found = bytes.count
            while index + needle.count <= bytes.count {
                if HTMLScanner.matches(bytes, at: index, needle) {
                    found = index
                    return index
                }
                index += 1
            }
            return nil
        }
    }
}

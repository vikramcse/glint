import Foundation

/// Turns raw bytes into text without trusting the file to declare its encoding.
enum TextDecoding {
    /// Decodes `data`, trying BOMs, strict UTF-8, BOM-less UTF-16, then Windows-1252 and Latin-1.
    /// Throws `ExtractionError.unsupported` for binary data.
    static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
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
    static func plainText(fromHTML html: String) -> String {
        var text = html
        for pattern in ["(?is)<script\\b.*?</script>", "(?is)<style\\b.*?</style>", "(?s)<!--.*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(
            of: "(?i)<(br|/p|/div|/li|/h[1-6]|/tr)\\b[^>]*>", with: "\n", options: .regularExpression
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decodeEntities(text)
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

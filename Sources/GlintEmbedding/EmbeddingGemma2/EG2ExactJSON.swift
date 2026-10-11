import Foundation

/// A JSON reader that keeps strings and object keys exactly as written: objects are ordered
/// key-value lists, so keys that are canonically equal in Swift stay distinct.
enum ExactJSON {
    indirect enum Value {
        case object([(key: String, value: Value)])
        case array([Value])
        case string(String)
        case number(Int)
        case other
    }

    struct ParseError: Error {
        let offset: Int
    }

    static func parse(_ data: Data) throws -> Value {
        try data.withUnsafeBytes { raw in
            var parser = Parser(bytes: raw.bindMemory(to: UInt8.self))
            let value = try parser.value()
            parser.skipWhitespace()
            guard parser.index == parser.bytes.count else { throw ParseError(offset: parser.index) }
            return value
        }
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ byte: UInt8) throws {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == byte else { throw ParseError(offset: index) }
            index += 1
        }

        mutating func value() throws -> Value {
            skipWhitespace()
            guard index < bytes.count else { throw ParseError(offset: index) }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                return .object(try object())
            case UInt8(ascii: "["):
                return .array(try array())
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return number()
            default:
                // true, false, null
                while index < bytes.count, (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(bytes[index]) { index += 1 }
                return .other
            }
        }

        private mutating func object() throws -> [(key: String, value: Value)] {
            index += 1
            var members: [(key: String, value: Value)] = []
            skipWhitespace()
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return members
            }
            while true {
                skipWhitespace()
                let key = try string()
                try expect(UInt8(ascii: ":"))
                members.append((key, try value()))
                if try endOfList(UInt8(ascii: "}")) { return members }
            }
        }

        private mutating func array() throws -> [Value] {
            index += 1
            var items: [Value] = []
            skipWhitespace()
            if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return items
            }
            while true {
                items.append(try value())
                if try endOfList(UInt8(ascii: "]")) { return items }
            }
        }

        /// Consumes the separator after a member: true at `close`, false at a comma.
        private mutating func endOfList(_ close: UInt8) throws -> Bool {
            skipWhitespace()
            guard index < bytes.count else { throw ParseError(offset: index) }
            index += 1
            if bytes[index - 1] == close { return true }
            guard bytes[index - 1] == UInt8(ascii: ",") else { throw ParseError(offset: index - 1) }
            return false
        }

        private mutating func number() -> Value {
            let start = index
            index += 1
            while index < bytes.count, "0123456789.eE+-".utf8.contains(bytes[index]) { index += 1 }
            if let integer = Int(String(lossyUTF8: bytes[start..<index])) { return .number(integer) }
            return .other
        }

        mutating func string() throws -> String {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseError(offset: index) }
            index += 1
            var scalars = String.UnicodeScalarView()
            var runStart = index
            func flushRun(_ end: Int) {
                if runStart < end { scalars.append(contentsOf: String(lossyUTF8: bytes[runStart..<end]).unicodeScalars) }
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    flushRun(index)
                    index += 1
                    return String(scalars)
                }
                guard byte == UInt8(ascii: "\\") else {
                    index += 1
                    continue
                }
                flushRun(index)
                index += 1
                guard index < bytes.count else { break }
                scalars.append(try escape())
                runStart = index
            }
            throw ParseError(offset: index)
        }

        /// The character for the escape at `index` (just past the backslash).
        private mutating func escape() throws -> Unicode.Scalar {
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "n"): return "\n"
            case UInt8(ascii: "t"): return "\t"
            case UInt8(ascii: "r"): return "\r"
            case UInt8(ascii: "b"): return "\u{08}"
            case UInt8(ascii: "f"): return "\u{0C}"
            case UInt8(ascii: "u"):
                var code = try hex4()
                if (0xD800..<0xDC00).contains(code), index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
                    bytes[index + 1] == UInt8(ascii: "u")
                {
                    index += 2
                    let low = try hex4()
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                }
                return Unicode.Scalar(code) ?? "\u{FFFD}"
            default: return Unicode.Scalar(escape)
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let code = UInt32(String(lossyUTF8: bytes[index..<(index + 4)]), radix: 16)
            else { throw ParseError(offset: index) }
            index += 4
            return code
        }
    }
}

extension String {
    /// Decodes UTF-8, replacing invalid sequences with U+FFFD as the reference tokenizer does.
    init(lossyUTF8 bytes: some Collection<UInt8>) {
        self.init(decoding: bytes, as: UTF8.self)
    }
}

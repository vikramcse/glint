import Foundation

/// How much a document really holds, for size limits that the size on disk alone would let
/// through: a package (`.rtfd`) is a folder, and Word and OpenDocument files are zip archives
/// that can expand far beyond their size on disk.
enum DocumentSize {
    /// Bytes on disk; for a package, its regular files added up. Symbolic links are not followed.
    static func onDisk(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard values?.isDirectory == true else { return Int64(values?.fileSize ?? 0) }
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total = total.addingReportingOverflow(Int64(values.fileSize ?? 0)).partialValue
        }
        return total
    }

    /// The uncompressed size of every entry in the zip archive at `url`, read from its central
    /// directory without inflating anything; `nil` when the file isn't a readable zip archive.
    /// Saturates at `Int64.max` rather than overflowing.
    static func zipUncompressedSize(_ url: URL) -> Int64? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return ZipDirectory(data: data)?.uncompressedSize()
    }
}

/// The parts of a zip archive's central directory needed to add up entry sizes.
struct ZipDirectory {
    private let bytes: [UInt8]
    private let start: Int
    private let size: Int
    private let entries: UInt64

    private static let endSignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let zip64EndSignature: UInt32 = 0x0606_4B50
    private static let entrySignature: UInt32 = 0x0201_4B50
    private static let endRecordLength = 22
    private static let entryHeaderLength = 46

    init?(data: Data) {
        let bytes = [UInt8](data)
        self.bytes = bytes
        // The end record sits in the last 22 bytes plus at most a 64 KB comment.
        let lowest = max(0, bytes.count - Self.endRecordLength - 0xFFFF)
        var end = bytes.count - Self.endRecordLength
        while end >= lowest, Self.read32(bytes, end) != Self.endSignature { end -= 1 }
        guard end >= lowest else { return nil }

        var entries = UInt64(Self.read16(bytes, end + 10))
        var size = UInt64(Self.read32(bytes, end + 12))
        var start = UInt64(Self.read32(bytes, end + 16))
        if entries == 0xFFFF || size == 0xFFFF_FFFF || start == 0xFFFF_FFFF {
            // Zip64: a locator just before the end record points at the larger record.
            let locator = end - 20
            guard locator >= 0, Self.read32(bytes, locator) == Self.zip64LocatorSignature,
                let record = Int(exactly: Self.read64(bytes, locator + 8)),
                record >= 0, record + 56 <= bytes.count, Self.read32(bytes, record) == Self.zip64EndSignature
            else { return nil }
            entries = Self.read64(bytes, record + 32)
            size = Self.read64(bytes, record + 40)
            start = Self.read64(bytes, record + 48)
        }
        guard let startOffset = Int(exactly: start), let length = Int(exactly: size),
            startOffset <= bytes.count, length <= bytes.count - startOffset
        else { return nil }
        self.start = startOffset
        self.size = length
        self.entries = entries
    }

    /// The sum of the entries' uncompressed sizes; `nil` when the directory is malformed.
    func uncompressedSize() -> Int64? {
        var total: Int64 = 0
        var offset = start
        let end = start + size
        var count: UInt64 = 0
        while count < entries {
            guard offset + Self.entryHeaderLength <= end, Self.read32(bytes, offset) == Self.entrySignature else { return nil }
            var entrySize = UInt64(Self.read32(bytes, offset + 24))
            let nameLength = Int(Self.read16(bytes, offset + 28))
            let extraLength = Int(Self.read16(bytes, offset + 30))
            let commentLength = Int(Self.read16(bytes, offset + 32))
            let extraStart = offset + Self.entryHeaderLength + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= end else { return nil }
            if entrySize == 0xFFFF_FFFF {
                // The real size is the first field of the Zip64 extra block.
                guard let zip64 = Self.zip64Size(bytes, from: extraStart, to: extraStart + extraLength) else { return nil }
                entrySize = zip64
            }
            let (sum, overflow) = total.addingReportingOverflow(Int64(clamping: entrySize))
            total = overflow ? .max : sum
            offset = next
            count += 1
        }
        return total
    }

    private static func zip64Size(_ bytes: [UInt8], from start: Int, to end: Int) -> UInt64? {
        var offset = start
        while offset + 4 <= end {
            let id = read16(bytes, offset)
            let length = Int(read16(bytes, offset + 2))
            if id == 0x0001 {
                return offset + 12 <= end ? read64(bytes, offset + 4) : nil
            }
            offset += 4 + length
        }
        return nil
    }

    private static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(read16(bytes, offset)) | UInt32(read16(bytes, offset + 2)) << 16
    }

    private static func read64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(read32(bytes, offset)) | UInt64(read32(bytes, offset + 4)) << 32
    }
}

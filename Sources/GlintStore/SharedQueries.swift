import Foundation
import GlintCore
import UniformTypeIdentifiers

/// Read queries used by both the writer and the reader connection.
extension SQLiteConnection {
    static let fileColumns =
        "id, source_id, path, name, kind, uti, size, modified, content_hash, status, indexed_at, duration, waveform"

    static func fileRecord(_ row: Row) -> FileRecord? {
        guard
            let path = row.text(2), let name = row.text(3),
            let kind = row.text(4).flatMap(MediaKind.init(rawValue:)),
            let status = FileStatus(rawValue: Int(row.int(9)))
        else { return nil }
        return FileRecord(
            id: FileID(row.int(0)),
            sourceID: SourceID(row.int(1)),
            path: path,
            name: name,
            kind: kind,
            contentType: row.text(5).flatMap { UTType($0) } ?? .data,
            size: row.int(6),
            modified: row.date(7),
            contentHash: row.text(8),
            status: status,
            indexedAt: row.isNull(10) ? nil : row.date(10),
            duration: row.isNull(11) ? nil : row.double(11),
            waveform: row.blob(12).map(VectorCodec.decodeWaveform)
        )
    }

    static func chunkRecord(_ row: Row) -> ChunkRecord? {
        guard let locatorJSON = row.text(3),
            let locator = try? JSONDecoder().decode(ChunkLocator.self, from: Data(locatorJSON.utf8))
        else { return nil }
        return ChunkRecord(
            id: ChunkID(row.int(0)),
            fileID: FileID(row.int(1)),
            ordinal: Int(row.int(2)),
            locator: locator,
            text: row.text(4),
            thumbnail: row.text(5)
        )
    }

    func counts() throws -> IndexCounts {
        var counts = IndexCounts()
        _ = try query("SELECT kind, status, COUNT(*) FROM files GROUP BY kind, status") { row in
            guard let kind = row.text(0).flatMap(MediaKind.init(rawValue:)),
                let status = FileStatus(rawValue: Int(row.int(1)))
            else { return }
            let count = Int(row.int(2))
            switch status {
            case .indexed: counts.indexed[kind, default: 0] += count
            case .pending: counts.pending[kind, default: 0] += count
            case .failed: counts.failed += count
            }
        }
        return counts
    }

    func sources() throws -> [SourceRecord] {
        try query(
            """
            SELECT s.id, s.path, s.bookmark, s.added_at, r.config FROM sources s
            LEFT JOIN remote_sources r ON r.source_id = s.id ORDER BY s.added_at
            """
        ) { row in
            SourceRecord(
                id: SourceID(row.int(0)), path: row.text(1) ?? "", bookmark: row.blob(2), addedAt: row.date(3),
                remote: row.text(4).flatMap { try? JSONDecoder().decode(RemoteSourceConfig.self, from: Data($0.utf8)) })
        }
    }

    func sourceItemCounts() throws -> [SourceID: Int] {
        let pairs = try query("SELECT source_id, COUNT(*) FROM files GROUP BY source_id") { row in
            (SourceID(row.int(0)), Int(row.int(1)))
        }
        return Dictionary(pairs, uniquingKeysWith: +)
    }

    /// File counts per source, by kind and status.
    func sourceCounts() throws -> [SourceID: IndexCounts] {
        var result: [SourceID: IndexCounts] = [:]
        _ = try query("SELECT source_id, kind, status, COUNT(*) FROM files GROUP BY source_id, kind, status") { row in
            guard let kind = row.text(1).flatMap(MediaKind.init(rawValue:)),
                let status = FileStatus(rawValue: Int(row.int(2)))
            else { return }
            let source = SourceID(row.int(0))
            let count = Int(row.int(3))
            switch status {
            case .indexed: result[source, default: IndexCounts()].indexed[kind, default: 0] += count
            case .pending: result[source, default: IndexCounts()].pending[kind, default: 0] += count
            case .failed: result[source, default: IndexCounts()].failed += count
            }
        }
        return result
    }

    func files(_ ids: [FileID]) throws -> [FileID: FileRecord] {
        guard !ids.isEmpty else { return [:] }
        var result: [FileID: FileRecord] = [:]
        for batch in ids.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let rows = try query(
                "SELECT \(Self.fileColumns) FROM files WHERE id IN (\(placeholders))",
                batch.map { .int($0.rawValue) }, cache: false,
                map: Self.fileRecord
            )
            for record in rows.compactMap({ $0 }) { result[record.id] = record }
        }
        return result
    }

    func setting(_ key: String) throws -> String? {
        try query("SELECT value FROM settings WHERE key = ?", [.text(key)]) { $0.text(0) }.first ?? nil
    }
}

extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}

extension ChunkLocator {
    var json: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"whole\":{}}"
    }
}

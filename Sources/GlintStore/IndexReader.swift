import Foundation
import GlintCore

/// Read-only access to the index for the search path. Runs on its own connection, so a
/// search never waits on the indexer's writer (WAL readers see the last committed state).
public actor IndexReader {
    private let db: SQLiteConnection

    /// Opens a reader. Create the `IndexWriter` first so the schema exists.
    public init(url: URL) throws {
        db = try SQLiteConnection(url: url, readOnly: true)
    }

    // MARK: Vectors

    /// Loads a page of vectors in `space`, ordered by chunk id, joined with file attributes.
    public func vectors(in space: VectorSpace, after: ChunkID?, limit: Int) throws -> [StoredVector] {
        try db.query(
            """
            SELECT v.chunk_id, v.file_id, v.data, f.kind, f.modified, f.path FROM vectors v
            JOIN files f ON f.id = v.file_id
            WHERE v.space = ? AND v.chunk_id > ? ORDER BY v.chunk_id LIMIT ?
            """,
            [.text(space.description), .int(after?.rawValue ?? 0), SQLValue(limit)]
        ) { row -> StoredVector? in
            guard let data = row.blob(2), let kind = row.text(3).flatMap(MediaKind.init(rawValue:)), let path = row.text(5)
            else { return nil }
            return StoredVector(
                chunkID: ChunkID(row.int(0)),
                fileID: FileID(row.int(1)),
                values: VectorCodec.decode(data),
                attributes: FileAttributes(kind: kind, modified: row.date(4), path: path)
            )
        }.compactMap { $0 }
    }

    /// Every vector of one file (used by "find similar" for an indexed example).
    public func vectors(forFile fileID: FileID, in space: VectorSpace) throws -> [(ChunkID, [Float])] {
        try db.query(
            "SELECT chunk_id, data FROM vectors WHERE file_id = ? AND space = ? ORDER BY chunk_id",
            [.int(fileID.rawValue), .text(space.description)]
        ) { row in (ChunkID(row.int(0)), row.blob(1).map(VectorCodec.decode) ?? []) }
    }

    // MARK: Keyword search

    /// BM25 ranks at most this many of the newest matches, which bounds keystroke latency
    /// when a short prefix matches most of the index. Everything still matches; only the
    /// ranking window is capped, and the semantic phase merges in moments later.
    public static let rankingWindow = 5_000

    /// Full-text matches in chunk text (documents, OCR, transcripts), best first.
    public func chunkMatches(_ match: String, limit: Int) throws -> [KeywordHit] {
        try db.query(
            """
            SELECT c.id, c.file_id, m.score, f.kind, f.modified, f.path
            FROM (\(Self.rankedMatches("chunks_fts"))) m
            JOIN chunks c ON c.id = m.rowid JOIN files f ON f.id = c.file_id
            ORDER BY m.score
            """,
            [.text(match), SQLValue(limit), SQLValue(Self.rankingWindow)],
            map: Self.hit(chunkColumn: 0, fileColumn: 1)
        ).compactMap { $0 }
    }

    /// Ranks matches of `?1` within the newest `?3` matching rows, returning the best `?2`.
    /// A rowid range keeps FTS5 on its fast path (an `IN` list does not).
    private static func rankedMatches(_ table: String) -> String {
        """
        SELECT rowid, bm25(\(table)) AS score FROM \(table)
        WHERE \(table) MATCH ?1 AND rowid >= coalesce(
            (SELECT min(rowid) FROM (SELECT rowid FROM \(table) WHERE \(table) MATCH ?1 ORDER BY rowid DESC LIMIT ?3)), 0)
        ORDER BY score LIMIT ?2
        """
    }

    /// Full-text matches in file names, best first. Includes files not yet indexed, so the
    /// first search works seconds after the initial scan.
    public func nameMatches(_ match: String, limit: Int) throws -> [KeywordHit] {
        try db.query(
            """
            SELECT NULL, f.id, m.score, f.kind, f.modified, f.path
            FROM (\(Self.rankedMatches("names_fts"))) m
            JOIN files f ON f.id = m.rowid
            ORDER BY m.score
            """,
            [.text(match), SQLValue(limit), SQLValue(Self.rankingWindow)],
            map: Self.hit(chunkColumn: nil, fileColumn: 1)
        ).compactMap { $0 }
    }

    private static func hit(chunkColumn: Int32?, fileColumn: Int32) -> (Row) -> KeywordHit? {
        { row in
            guard let kind = row.text(3).flatMap(MediaKind.init(rawValue:)), let path = row.text(5) else { return nil }
            return KeywordHit(
                fileID: FileID(row.int(fileColumn)),
                chunkID: chunkColumn.map { ChunkID(row.int($0)) },
                bm25: row.double(2),
                attributes: FileAttributes(kind: kind, modified: row.date(4), path: path)
            )
        }
    }

    // MARK: Records

    public func files(_ ids: [FileID]) throws -> [FileID: FileRecord] { try db.files(ids) }

    public func chunks(_ ids: [ChunkID]) throws -> [ChunkID: ChunkRecord] {
        guard !ids.isEmpty else { return [:] }
        var result: [ChunkID: ChunkRecord] = [:]
        for batch in ids.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let rows = try db.query(
                "SELECT id, file_id, ordinal, locator, text, thumb, tags FROM chunks WHERE id IN (\(placeholders))",
                batch.map { .int($0.rawValue) },
                map: SQLiteConnection.chunkRecord
            )
            for record in rows.compactMap({ $0 }) { result[record.id] = record }
        }
        return result
    }

    /// The first chunk of each file (for name-only matches and library browsing).
    public func firstChunks(of fileIDs: [FileID]) throws -> [FileID: ChunkRecord] {
        guard !fileIDs.isEmpty else { return [:] }
        var result: [FileID: ChunkRecord] = [:]
        for batch in fileIDs.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let rows = try db.query(
                """
                SELECT id, file_id, ordinal, locator, text, thumb, tags FROM chunks
                WHERE file_id IN (\(placeholders)) AND ordinal = 0
                """,
                batch.map { .int($0.rawValue) },
                map: SQLiteConnection.chunkRecord
            )
            for record in rows.compactMap({ $0 }) { result[record.fileID] = record }
        }
        return result
    }

    /// Recently modified files for library browsing, newest first.
    public func recentFiles(kinds: Set<MediaKind>, limit: Int, offset: Int = 0) throws -> [FileRecord] {
        let kindList = kinds.isEmpty ? MediaKind.allCases : kinds.sorted()
        let placeholders = Array(repeating: "?", count: kindList.count).joined(separator: ",")
        return try db.query(
            """
            SELECT \(SQLiteConnection.fileColumns) FROM files
            WHERE kind IN (\(placeholders)) ORDER BY modified DESC LIMIT ? OFFSET ?
            """,
            kindList.map { .text($0.rawValue) } + [SQLValue(limit), SQLValue(offset)],
            map: SQLiteConnection.fileRecord
        ).compactMap { $0 }
    }

    public func file(atPath path: String) throws -> FileRecord? {
        try db.query("SELECT \(SQLiteConnection.fileColumns) FROM files WHERE path = ?", [.text(path)], map: SQLiteConnection.fileRecord)
            .first ?? nil
    }

    public func counts() throws -> IndexCounts { try db.counts() }

    public func sources() throws -> [SourceRecord] { try db.sources() }

    public func setting(_ key: String) throws -> String? { try db.setting(key) }

    public func savedSearches() throws -> [SavedSearch] {
        try db.query("SELECT id, name, query, filter, created_at FROM saved_searches ORDER BY name") { row in
            let filter = row.text(3).flatMap { try? JSONDecoder().decode(SearchFilter.self, from: Data($0.utf8)) } ?? .none
            return SavedSearch(id: row.int(0), name: row.text(1) ?? "", query: row.text(2) ?? "", filter: filter, createdAt: row.date(4))
        }
    }
}

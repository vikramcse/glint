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
                "SELECT id, file_id, ordinal, locator, text, thumb FROM chunks WHERE id IN (\(placeholders))",
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
                SELECT id, file_id, ordinal, locator, text, thumb FROM chunks
                WHERE file_id IN (\(placeholders)) AND ordinal = 0
                """,
                batch.map { .int($0.rawValue) },
                map: SQLiteConnection.chunkRecord
            )
            for record in rows.compactMap({ $0 }) { result[record.fileID] = record }
        }
        return result
    }

    /// Files for library browsing, in `sort` order (newest first by default), optionally only
    /// those under `folder`.
    public func recentFiles(
        kinds: Set<MediaKind>, folder: String? = nil, sort: ResultSort = .newestFirst, limit: Int, offset: Int = 0
    ) throws -> [FileRecord] {
        let kindList = kinds.isEmpty ? MediaKind.allCases : kinds.sorted()
        let placeholders = Array(repeating: "?", count: kindList.count).joined(separator: ",")
        var arguments: [SQLValue] = kindList.map { .text($0.rawValue) }
        var folderClause = ""
        if let folder {
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            folderClause = "AND substr(path, 1, ?) = ?"
            arguments += [SQLValue(prefix.unicodeScalars.count), .text(prefix)]
        }
        return try db.query(
            """
            SELECT \(SQLiteConnection.fileColumns) FROM files
            WHERE kind IN (\(placeholders)) \(folderClause) ORDER BY \(Self.orderClause(sort)) LIMIT ? OFFSET ?
            """,
            arguments + [SQLValue(limit), SQLValue(offset)],
            map: SQLiteConnection.fileRecord
        ).compactMap { $0 }
    }

    /// `ORDER BY` terms for a library sort. Ties fall back to newest first, then id, so paging is stable.
    static func orderClause(_ sort: ResultSort) -> String {
        let direction = sort.ascending ? "ASC" : "DESC"
        let primary: String? =
            switch sort.field {
            case .relevance: nil
            case .modified: "modified \(direction)"
            case .name: "name COLLATE NOCASE \(direction)"
            case .size: "size \(direction)"
            case .kind: "kind \(direction)"
            case .duration: "duration IS NULL, duration \(direction)"
            }
        let tieBreak = sort.field == .modified ? "id \(direction)" : "modified DESC, id DESC"
        return [primary ?? "modified DESC", tieBreak].joined(separator: ", ")
    }

    /// Files whose names contain every one of `words` anywhere (case-insensitive), so "4821"
    /// finds IMG_4821.jpg. Exact names first, then names starting with the query, then shorter
    /// and newer names.
    public func filesNamed(containing words: [String], limit: Int) throws -> [KeywordHit] {
        let words = words.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let whole = words.joined(separator: " ")
        let conditions = Array(repeating: "name LIKE '%' || ? || '%' ESCAPE '\\'", count: words.count).joined(separator: " AND ")
        return try db.query(
            """
            SELECT NULL, id, 0, kind, modified, path FROM files WHERE \(conditions)
            ORDER BY lower(name) = lower(?) DESC, name LIKE ? || '%' ESCAPE '\\' DESC, length(name), modified DESC, id DESC
            LIMIT ?
            """,
            words.map { .text(Self.escapeLike($0)) } + [.text(whole), .text(Self.escapeLike(whole)), SQLValue(limit)],
            map: Self.hit(chunkColumn: nil, fileColumn: 1)
        ).compactMap { $0 }
    }

    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: People

    /// A person as stored: the name, how many files they appear in and their clearest face.
    public struct PersonRow: Sendable, Hashable {
        public var id: PersonID
        public var name: String?
        public var fileCount: Int
        public var faceThumbnail: String?
    }

    /// People seen in at least `minimumFiles` files, plus everyone named; named first, then by
    /// how many files they appear in. A face seen once is usually a stranger in the background.
    /// Copies of one photo in several folders count once.
    public func people(minimumFiles: Int) throws -> [PersonRow] {
        try db.query(
            """
            SELECT p.id, p.name, COUNT(DISTINCT coalesce(fi.content_hash, fi.id)) AS files,
                (SELECT thumb FROM faces WHERE person_id = p.id AND thumb IS NOT NULL ORDER BY quality DESC LIMIT 1)
            FROM people p JOIN faces f ON f.person_id = p.id JOIN files fi ON fi.id = f.file_id
            GROUP BY p.id HAVING files >= ? OR p.name IS NOT NULL
            ORDER BY p.name IS NULL, files DESC, p.id
            """,
            [SQLValue(minimumFiles)]
        ) { row in
            PersonRow(id: PersonID(row.int(0)), name: row.text(1), fileCount: Int(row.int(2)), faceThumbnail: row.text(3))
        }
    }

    /// The files a person appears in, newest first, each with the chunk showing their clearest
    /// face (the moment in a video, the page or photo otherwise). Of several copies of one
    /// photo, only the most recently modified is listed.
    public func files(of person: PersonID) throws -> [(file: FileRecord, chunk: ChunkRecord?)] {
        let best = try db.query(
            """
            SELECT f.file_id, c.id, max(f.quality) FROM faces f
            LEFT JOIN chunks c ON c.file_id = f.file_id AND c.ordinal = f.ordinal
            WHERE f.person_id = ? GROUP BY f.file_id
            """,
            [.int(person.rawValue)]
        ) { row in (FileID(row.int(0)), row.isNull(1) ? nil : ChunkID(row.int(1))) }
        let records = try db.files(best.map(\.0))
        let chunks = try chunks(best.compactMap(\.1))
        let sorted = best.compactMap { fileID, chunkID in
            records[fileID].map { ($0, chunkID.flatMap { chunks[$0] }) }
        }.sorted { ($0.0.modified, $0.0.id) > ($1.0.modified, $1.0.id) }
        var seen: Set<String> = []
        return sorted.filter { file, _ in file.contentHash.map { seen.insert($0).inserted } ?? true }
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

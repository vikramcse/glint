import Foundation
import GlintCore

/// The single writer of the index database. Every multi-row change is one transaction, so a
/// crash or quit mid-file loses nothing: the file simply stays pending.
public actor IndexWriter {
    private let db: SQLiteConnection
    private let now: @Sendable () -> Date

    /// Files are retried this many times before they are marked failed (guards against a file
    /// that crashes an extractor every time).
    public static let maxAttempts = 3

    public init(url: URL, now: @escaping @Sendable () -> Date = Date.init) throws {
        db = try SQLiteConnection(url: url)
        try Schema.migrate(db)
        self.now = now
    }

    // MARK: Sources

    public func addSource(path: String, bookmark: Data?) throws -> SourceID {
        if let existing = try db.scalarInt("SELECT id FROM sources WHERE path = ?", [.text(path)]) {
            return SourceID(existing)
        }
        try db.run(
            "INSERT INTO sources(path, bookmark, added_at) VALUES (?, ?, ?)",
            [.text(path), bookmark.map(SQLValue.blob) ?? .null, SQLValue(now())]
        )
        return SourceID(db.lastInsertRowID)
    }

    /// Removes a source and every file under it. Returns the removed file ids.
    public func removeSource(_ id: SourceID) throws -> [FileID] {
        try db.transaction {
            let ids = try db.query("SELECT id FROM files WHERE source_id = ?", [.int(id.rawValue)]) { FileID($0.int(0)) }
            try db.run("DELETE FROM sources WHERE id = ?", [.int(id.rawValue)])
            return ids
        }
    }

    public func sources() throws -> [SourceRecord] { try db.sources() }
    public func sourceItemCounts() throws -> [SourceID: Int] { try db.sourceItemCounts() }

    // MARK: Scanning and file-system changes

    /// A file that moved or was renamed; its chunks and vectors were kept.
    public struct MovedFile: Sendable, Hashable {
        public var id: FileID
        public var attributes: FileAttributes
    }

    /// Result of applying a scan or a batch of file-system changes.
    public struct ReconcileResult: Sendable, Hashable {
        public var added = 0
        public var changed = 0
        public var moved: [MovedFile] = []
        public var removed: [FileID] = []

        public var isEmpty: Bool { added == 0 && changed == 0 && moved.isEmpty && removed.isEmpty }
    }

    /// Makes the stored files under `scope` (or the whole source) match `scanned`: new files are
    /// added as pending, changed files go back to pending, moved files keep their vectors, and
    /// files no longer present are deleted.
    public func reconcile(sourceID: SourceID, scanned: [ScannedFile], scope: String? = nil) throws -> ReconcileResult {
        try db.transaction {
            var stale: [String: StoredFile] = [:]
            if let scope {
                for file in try storedFiles(atOrBelow: scope) where file.sourceID == sourceID { stale[file.path] = file }
            } else {
                let rows = try db.query("SELECT id, source_id, path, size, modified FROM files WHERE source_id = ?", [.int(sourceID.rawValue)], map: StoredFile.init)
                for file in rows.compactMap({ $0 }) { stale[file.path] = file }
            }
            return try apply(upserts: scanned.map { (sourceID, $0) }, stale: &stale, removeStale: true)
        }
    }

    /// Applies a batch of watcher events: paths that exist are upserted, vanished paths (and
    /// everything below them) are removed, and a vanished file matched by a new path with the
    /// same size, modification date and extension is treated as a move.
    public func applyChanges(upserts: [(SourceID, ScannedFile)], removedPaths: [String]) throws -> ReconcileResult {
        try db.transaction {
            var stale: [String: StoredFile] = [:]
            for path in removedPaths {
                for file in try storedFiles(atOrBelow: path) { stale[file.path] = file }
            }
            return try apply(upserts: upserts, stale: &stale, removeStale: true)
        }
    }

    /// Deletes files at `path` or anywhere below it. Returns the removed ids.
    public func removeFiles(atOrBelow path: String) throws -> [FileID] {
        try db.transaction {
            let ids = try storedFiles(atOrBelow: path).map(\.id)
            for id in ids { try db.run("DELETE FROM files WHERE id = ?", [.int(id.rawValue)]) }
            return ids
        }
    }

    struct StoredFile {
        var id: FileID
        var sourceID: SourceID
        var path: String
        var size: Int64
        var modified: Double

        init?(_ row: Row) {
            guard let path = row.text(2) else { return nil }
            id = FileID(row.int(0))
            sourceID = SourceID(row.int(1))
            self.path = path
            size = row.int(3)
            modified = row.double(4)
        }

        var moveKey: String { "\(size)|\(Int64(modified * 1_000))|\(URL(fileURLWithPath: path).pathExtension.lowercased())" }
    }

    private func storedFiles(atOrBelow path: String) throws -> [StoredFile] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return try db.query(
            "SELECT id, source_id, path, size, modified FROM files WHERE path = ? OR substr(path, 1, ?) = ?",
            [.text(path), .int(Int64(prefix.count)), .text(prefix)],
            map: StoredFile.init
        ).compactMap { $0 }
    }

    /// Core of reconcile and applyChanges. Must run inside a transaction.
    private func apply(upserts: [(SourceID, ScannedFile)], stale: inout [String: StoredFile], removeStale: Bool) throws -> ReconcileResult {
        var result = ReconcileResult()
        var additions: [(SourceID, ScannedFile)] = []
        for (sourceID, file) in upserts {
            let modified = file.modified.timeIntervalSince1970
            var stored = stale.removeValue(forKey: file.path)
            if stored == nil {
                stored = try db.query(
                    "SELECT id, source_id, path, size, modified FROM files WHERE path = ?", [.text(file.path)], map: StoredFile.init
                ).first ?? nil
            }
            if let stored {
                guard stored.size != file.size || abs(stored.modified - modified) > 0.001 else { continue }
                try db.run(
                    "UPDATE files SET size = ?, modified = ?, kind = ?, uti = ?, priority = ?, status = 0, attempts = 0, error = NULL WHERE id = ?",
                    [.int(file.size), .double(modified), .text(file.kind.rawValue), .text(file.contentType.identifier),
                     SQLValue(file.kind.indexingPriority), .int(stored.id.rawValue)]
                )
                result.changed += 1
            } else {
                additions.append((sourceID, file))
            }
        }

        // Pair vanished files with new paths to detect moves and renames.
        var vanishedByKey: [String: [StoredFile]] = [:]
        for file in stale.values { vanishedByKey[file.moveKey, default: []].append(file) }
        for (sourceID, file) in additions {
            let key = "\(file.size)|\(Int64(file.modified.timeIntervalSince1970 * 1_000))|\(URL(fileURLWithPath: file.path).pathExtension.lowercased())"
            if var candidates = vanishedByKey[key], let match = candidates.popLast() {
                vanishedByKey[key] = candidates
                stale[match.path] = nil
                try db.run(
                    "UPDATE files SET path = ?, name = ?, source_id = ? WHERE id = ?",
                    [.text(file.path), .text(URL(fileURLWithPath: file.path).lastPathComponent), .int(sourceID.rawValue), .int(match.id.rawValue)]
                )
                result.moved.append(MovedFile(id: match.id, attributes: FileAttributes(kind: file.kind, modified: file.modified, path: file.path)))
            } else {
                try insert(file, sourceID: sourceID)
                result.added += 1
            }
        }

        if removeStale {
            for file in stale.values {
                try db.run("DELETE FROM files WHERE id = ?", [.int(file.id.rawValue)])
                result.removed.append(file.id)
            }
        }
        return result
    }

    private func insert(_ file: ScannedFile, sourceID: SourceID) throws {
        try db.run(
            """
            INSERT INTO files(source_id, path, name, kind, uti, size, modified, status, priority)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)
            """,
            [.int(sourceID.rawValue), .text(file.path), .text(URL(fileURLWithPath: file.path).lastPathComponent),
             .text(file.kind.rawValue), .text(file.contentType.identifier), .int(file.size),
             .double(file.modified.timeIntervalSince1970), SQLValue(file.kind.indexingPriority)]
        )
    }

    // MARK: Queue

    /// Claims up to `limit` pending files of the allowed kinds, highest priority first
    /// (documents and images, then audio, then video; newest first within a priority).
    /// Each claim counts as an attempt, so a file that crashes the app is not retried forever.
    public func claimPending(limit: Int, kinds: Set<MediaKind>) throws -> [FileRecord] {
        guard !kinds.isEmpty, limit > 0 else { return [] }
        return try db.transaction {
            let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ",")
            let records = try db.query(
                """
                SELECT \(SQLiteConnection.fileColumns) FROM files
                WHERE status = 0 AND attempts < ? AND kind IN (\(placeholders))
                ORDER BY priority, modified DESC LIMIT ?
                """,
                [SQLValue(Self.maxAttempts)] + kinds.sorted().map { .text($0.rawValue) } + [SQLValue(limit)],
                map: SQLiteConnection.fileRecord
            ).compactMap { $0 }
            for record in records {
                try db.run("UPDATE files SET attempts = attempts + 1 WHERE id = ?", [.int(record.id.rawValue)])
            }
            return records
        }
    }

    /// Marks files that ran out of attempts as failed. Returns how many changed.
    public func failExhausted() throws -> Int {
        try db.run("UPDATE files SET status = 2, error = 'attempts' WHERE status = 0 AND attempts >= ?", [SQLValue(Self.maxAttempts)])
        return db.changes
    }

    public func markFailed(_ id: FileID, category: ErrorCategory) throws {
        try db.run("UPDATE files SET status = 2, error = ? WHERE id = ?", [.text(category.rawValue), .int(id.rawValue)])
    }

    /// Returns a file to the queue without counting the attempt (for example when indexing
    /// was paused or cancelled mid-file).
    public func release(_ id: FileID) throws {
        try db.run("UPDATE files SET attempts = max(attempts - 1, 0) WHERE id = ? AND status = 0", [.int(id.rawValue)])
    }

    /// Sends indexed files of `kinds` back to the queue (for example PDFs after an upgrade
    /// unlocks visual page search) and failed files back for another try.
    public func requeue(kinds: Set<MediaKind>, includeFailed: Bool = false) throws {
        for kind in kinds {
            try db.run("UPDATE files SET status = 0, attempts = 0 WHERE kind = ? AND status = 1", [.text(kind.rawValue)])
        }
        if includeFailed {
            try db.run("UPDATE files SET status = 0, attempts = 0, error = NULL WHERE status = 2")
        }
    }

    /// Sends files indexed in a different vector space back to the queue (model switch).
    public func requeueFiles(notIn space: VectorSpace) throws -> Int {
        try db.run("UPDATE files SET status = 0, attempts = 0 WHERE status = 1 AND space IS NOT ?", [.text(space.description)])
        return db.changes
    }

    // MARK: Commit

    /// Replaces a file's chunks and vectors and marks it indexed, in one transaction.
    /// Returns the committed vectors, or an empty array if the file vanished meanwhile.
    public func commit(
        fileID: FileID,
        contentHash: String,
        space: VectorSpace,
        chunks: [ChunkWrite],
        media: FileMedia = FileMedia()
    ) throws -> [CommittedVector] {
        try db.transaction {
            guard try db.scalarInt("SELECT 1 FROM files WHERE id = ?", [.int(fileID.rawValue)]) != nil else { return [] }
            try db.run("DELETE FROM chunks WHERE file_id = ?", [.int(fileID.rawValue)])
            var committed: [CommittedVector] = []
            for chunk in chunks {
                try db.run(
                    "INSERT INTO chunks(file_id, ordinal, locator, text, thumb) VALUES (?, ?, ?, ?, ?)",
                    [.int(fileID.rawValue), SQLValue(chunk.ordinal), .text(chunk.locator.json),
                     SQLValue(chunk.text), SQLValue(chunk.thumbnail)]
                )
                let chunkID = ChunkID(db.lastInsertRowID)
                if let vector = chunk.vector {
                    try db.run(
                        "INSERT INTO vectors(chunk_id, file_id, space, data) VALUES (?, ?, ?, ?)",
                        [.int(chunkID.rawValue), .int(fileID.rawValue), .text(space.description), .blob(VectorCodec.encode(vector))]
                    )
                    committed.append(CommittedVector(chunkID: chunkID, values: vector))
                }
            }
            try db.run(
                """
                UPDATE files SET status = 1, content_hash = ?, error = NULL, indexed_at = ?, space = ?,
                duration = ?, waveform = ? WHERE id = ?
                """,
                [.text(contentHash), SQLValue(now()), .text(space.description),
                 media.duration.map(SQLValue.double) ?? .null,
                 media.waveform.map { .blob(VectorCodec.encodeWaveform($0)) } ?? .null,
                 .int(fileID.rawValue)]
            )
            return committed
        }
    }

    /// An indexed file with the same content in the same space, so a copy or move reuses its vectors.
    public func indexedDuplicate(contentHash: String, space: VectorSpace, excluding fileID: FileID) throws -> FileID? {
        try db.scalarInt(
            "SELECT id FROM files WHERE content_hash = ? AND status = 1 AND space = ? AND id != ? LIMIT 1",
            [.text(contentHash), .text(space.description), .int(fileID.rawValue)]
        ).map { FileID($0) }
    }

    /// Copies chunks, vectors and display data from `source` to `target` and marks it indexed.
    public func copyIndex(from source: FileID, to target: FileID, contentHash: String, space: VectorSpace) throws -> [CommittedVector] {
        let chunks = try db.query(
            """
            SELECT c.ordinal, c.locator, c.text, c.thumb, v.data FROM chunks c
            LEFT JOIN vectors v ON v.chunk_id = c.id AND v.space = ?
            WHERE c.file_id = ? ORDER BY c.ordinal
            """,
            [.text(space.description), .int(source.rawValue)]
        ) { row -> ChunkWrite? in
            guard let json = row.text(1),
                let locator = try? JSONDecoder().decode(ChunkLocator.self, from: Data(json.utf8))
            else { return nil }
            return ChunkWrite(
                ordinal: Int(row.int(0)), locator: locator, text: row.text(2), thumbnail: row.text(3),
                vector: row.blob(4).map(VectorCodec.decode)
            )
        }.compactMap { $0 }
        let media = try db.query("SELECT duration, waveform FROM files WHERE id = ?", [.int(source.rawValue)]) { row in
            FileMedia(duration: row.isNull(0) ? nil : row.double(0), waveform: row.blob(1).map(VectorCodec.decodeWaveform))
        }.first ?? FileMedia()
        return try commit(fileID: target, contentHash: contentHash, space: space, chunks: chunks, media: media)
    }

    // MARK: Status, settings and maintenance

    public func counts() throws -> IndexCounts { try db.counts() }

    public func setting(_ key: String) throws -> String? { try db.setting(key) }

    public func setSetting(_ key: String, value: String) throws {
        try db.run("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(key), .text(value)])
    }

    public func saveSearch(name: String, query: String, filter: SearchFilter) throws -> SavedSearch {
        let filterJSON = (try? JSONEncoder().encode(filter)).flatMap { String(data: $0, encoding: .utf8) }
        let created = now()
        try db.run(
            "INSERT INTO saved_searches(name, query, filter, created_at) VALUES (?, ?, ?, ?)",
            [.text(name), .text(query), SQLValue(filterJSON), SQLValue(created)]
        )
        return SavedSearch(id: db.lastInsertRowID, name: name, query: query, filter: filter, createdAt: created)
    }

    public func deleteSavedSearch(id: Int64) throws {
        try db.run("DELETE FROM saved_searches WHERE id = ?", [.int(id)])
    }

    /// Removes every derived row (files, chunks, vectors, keyword index), keeping sources and settings.
    public func deleteDerivedData() throws {
        try db.transaction {
            try db.run("DELETE FROM files")
            try db.run("INSERT INTO chunks_fts(chunks_fts) VALUES ('rebuild')")
            try db.run("INSERT INTO names_fts(names_fts) VALUES ('rebuild')")
        }
        try db.execute("VACUUM")
    }

    /// Optimizes the full-text indexes; run occasionally when idle.
    public func optimize() throws {
        try db.run("INSERT INTO chunks_fts(chunks_fts) VALUES ('optimize')")
        try db.run("INSERT INTO names_fts(names_fts) VALUES ('optimize')")
        try db.execute("PRAGMA optimize")
    }
}

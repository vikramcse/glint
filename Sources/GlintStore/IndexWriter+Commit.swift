import Foundation
import GlintCore

// MARK: Commit

extension IndexWriter {
    /// Replaces a file's chunks and vectors and marks it indexed, in one transaction.
    /// Returns the committed vectors, or an empty array if the file vanished or changed
    /// from `version` meanwhile (it stays pending, so the newer version is indexed next).
    public func commit(
        fileID: FileID,
        contentHash: String,
        space: VectorSpace,
        chunks: [ChunkWrite],
        media: FileMedia = FileMedia(),
        version: FileVersion? = nil
    ) throws -> [CommittedVector] {
        let file = FileCommit(fileID: fileID, contentHash: contentHash, space: space, chunks: chunks, media: media, version: version)
        return try transaction { orphans in try write(file, orphans: &orphans) }
    }

    /// Commits several files in one transaction (group commit). Each file is written whole, so
    /// the guarantee is unchanged: a file is either fully indexed or still pending. Returns the
    /// committed vectors per file (empty for files that vanished meanwhile).
    public func commitMany(_ files: [FileCommit]) throws -> [FileID: [CommittedVector]] {
        guard !files.isEmpty else { return [:] }
        return try transaction { orphans in
            var result: [FileID: [CommittedVector]] = [:]
            for file in files { result[file.fileID] = try write(file, orphans: &orphans) }
            return result
        }
    }

    /// Thumbnails that committed files no longer use (their content changed); the caller deletes
    /// them from disk.
    public func takeOrphanedThumbnails() -> [String] {
        defer { orphanedThumbnails = [] }
        return orphanedThumbnails
    }

    /// The thumbnails and face crops a file's rows point at.
    func thumbnails(of fileID: FileID) throws -> [String] {
        try db.query(
            """
            SELECT thumb FROM chunks WHERE file_id = ?1 AND thumb IS NOT NULL
            UNION SELECT thumb FROM faces WHERE file_id = ?1 AND thumb IS NOT NULL
            """,
            [.int(fileID.rawValue)]
        ) { $0.text(0) }.compactMap { $0 }
    }

    /// The thumbnails no chunk or face uses any more. Thumbnails are keyed by content hash, so
    /// copies of a file elsewhere may still share them.
    func unreferenced(_ thumbnails: [String]) throws -> [String] {
        try Set(thumbnails).sorted().filter { thumb in
            try db.scalarInt(
                "SELECT 1 FROM chunks WHERE thumb = ?1 UNION ALL SELECT 1 FROM faces WHERE thumb = ?1 LIMIT 1", [.text(thumb)]) == nil
        }
    }

    /// A file as it is stored now; its path may have changed since it was claimed.
    public func file(_ id: FileID) throws -> FileRecord? {
        try db.files([id])[id]
    }

    /// Runs `body` in a transaction and keeps the thumbnails it orphaned once it commits; a
    /// rolled-back write still uses them.
    private func transaction<T>(_ body: (inout [String]) throws -> T) throws -> T {
        var orphans: [String] = []
        let result = try db.transaction { try body(&orphans) }
        orphanedThumbnails += orphans
        return result
    }

    /// Writes one file's rows. Must run inside a transaction.
    private func write(_ file: FileCommit, orphans: inout [String]) throws -> [CommittedVector] {
        let fileID = file.fileID
        guard try isCurrent(fileID, version: file.version) else { return [] }
        let previousThumbnails = try thumbnails(of: fileID)
        try db.run("DELETE FROM chunks WHERE file_id = ?", [.int(fileID.rawValue)])
        var committed: [CommittedVector] = []
        for chunk in file.chunks {
            try db.run(
                "INSERT INTO chunks(file_id, ordinal, locator, text, thumb) VALUES (?, ?, ?, ?, ?)",
                [
                    .int(fileID.rawValue), SQLValue(chunk.ordinal), .text(chunk.locator.json),
                    SQLValue(chunk.text), SQLValue(chunk.thumbnail),
                ]
            )
            let chunkID = ChunkID(db.lastInsertRowID)
            if let vector = chunk.vector {
                try db.run(
                    "INSERT INTO vectors(chunk_id, file_id, space, data) VALUES (?, ?, ?, ?)",
                    [.int(chunkID.rawValue), .int(fileID.rawValue), .text(file.space.description), .blob(VectorCodec.encode(vector))]
                )
                committed.append(CommittedVector(chunkID: chunkID, values: vector))
            }
        }
        try writeFaces(of: fileID, chunks: file.chunks)
        try db.run(
            """
            UPDATE files SET status = 1, content_hash = ?, error = NULL, indexed_at = ?, space = ?,
            duration = ?, waveform = ? WHERE id = ?
            """,
            [
                .text(file.contentHash), SQLValue(now()), .text(file.space.description),
                file.media.duration.map(SQLValue.double) ?? .null,
                file.media.waveform.map { .blob(VectorCodec.encodeWaveform($0)) } ?? .null,
                .int(fileID.rawValue),
            ]
        )
        // Changed content gets thumbnails under its new hash; the old ones may now be unused.
        orphans += try unreferenced(previousThumbnails)
        return committed
    }

    /// An indexed file with the same content in the same space, so a copy or move reuses its vectors.
    public func indexedDuplicate(contentHash: String, space: VectorSpace, excluding fileID: FileID) throws -> FileID? {
        try db.scalarInt(
            "SELECT id FROM files WHERE content_hash = ? AND status = 1 AND space = ? AND id != ? LIMIT 1",
            [.text(contentHash), .text(space.description), .int(fileID.rawValue)]
        ).map { FileID($0) }
    }

    /// Copies chunks, vectors, faces and display data from `source` to `target` and marks it indexed.
    public func copyIndex(
        from source: FileID, to target: FileID, contentHash: String, space: VectorSpace, version: FileVersion? = nil
    ) throws -> [CommittedVector] {
        try transaction { orphans in
            try write(
                duplicate(of: source, as: target, contentHash: contentHash, space: space, version: version), orphans: &orphans)
        }
    }

    /// Finds an indexed file with the same content and copies its index to `target`, in one
    /// transaction, so the original cannot vanish in between. Returns `nil` when there is no
    /// such file or it has no chunks; the caller then extracts the file itself.
    public func copyIndexFromDuplicate(
        to target: FileID, contentHash: String, space: VectorSpace, version: FileVersion? = nil
    ) throws -> [CommittedVector]? {
        try transaction { orphans in
            guard let source = try indexedDuplicate(contentHash: contentHash, space: space, excluding: target) else { return nil }
            let file = try duplicate(of: source, as: target, contentHash: contentHash, space: space, version: version)
            guard !file.chunks.isEmpty else { return nil }
            return try write(file, orphans: &orphans)
        }
    }

    /// `source`'s stored rows as a commit for `target`.
    private func duplicate(
        of source: FileID, as target: FileID, contentHash: String, space: VectorSpace, version: FileVersion?
    ) throws -> FileCommit {
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
        let faces = try faceWrites(of: source)
        let chunksWithFaces = chunks.map { chunk in
            var chunk = chunk
            chunk.faces = faces[chunk.ordinal] ?? []
            return chunk
        }
        let media =
            try db.query("SELECT duration, waveform FROM files WHERE id = ?", [.int(source.rawValue)]) { row in
                FileMedia(duration: row.isNull(0) ? nil : row.double(0), waveform: row.blob(1).map(VectorCodec.decodeWaveform))
            }.first ?? FileMedia()
        return FileCommit(
            fileID: target, contentHash: contentHash, space: space, chunks: chunksWithFaces, media: media, version: version)
    }
}

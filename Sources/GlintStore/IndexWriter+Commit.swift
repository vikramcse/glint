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
        return try db.transaction { try write(file) }
    }

    /// Commits several files in one transaction (group commit). Each file is written whole, so
    /// the guarantee is unchanged: a file is either fully indexed or still pending. Returns the
    /// committed vectors per file (empty for files that vanished meanwhile).
    public func commitMany(_ files: [FileCommit]) throws -> [FileID: [CommittedVector]] {
        guard !files.isEmpty else { return [:] }
        return try db.transaction {
            var result: [FileID: [CommittedVector]] = [:]
            for file in files { result[file.fileID] = try write(file) }
            return result
        }
    }

    /// Writes one file's rows. Must run inside a transaction.
    private func write(_ file: FileCommit) throws -> [CommittedVector] {
        let fileID = file.fileID
        guard try isCurrent(fileID, version: file.version) else { return [] }
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
        return committed
    }

    /// An indexed file with the same content in the same space, so a copy or move reuses its vectors.
    public func indexedDuplicate(contentHash: String, space: VectorSpace, excluding fileID: FileID) throws -> FileID? {
        try db.scalarInt(
            "SELECT id FROM files WHERE content_hash = ? AND status = 1 AND space = ? AND id != ? LIMIT 1",
            [.text(contentHash), .text(space.description), .int(fileID.rawValue)]
        ).map { FileID($0) }
    }

    /// Copies chunks, vectors and display data from `source` to `target` and marks it indexed.
    public func copyIndex(
        from source: FileID, to target: FileID, contentHash: String, space: VectorSpace, version: FileVersion? = nil
    ) throws -> [CommittedVector] {
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
        let media =
            try db.query("SELECT duration, waveform FROM files WHERE id = ?", [.int(source.rawValue)]) { row in
                FileMedia(duration: row.isNull(0) ? nil : row.double(0), waveform: row.blob(1).map(VectorCodec.decodeWaveform))
            }.first ?? FileMedia()
        return try commit(fileID: target, contentHash: contentHash, space: space, chunks: chunks, media: media, version: version)
    }
}

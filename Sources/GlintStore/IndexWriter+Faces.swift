import CoreGraphics
import Foundation
import GlintCore

// MARK: Faces and people

extension IndexWriter {
    /// Settings key present while photos and videos indexed before faces existed await a rescan.
    public static let facesBackfillKey = "faces_backfill"

    /// Replaces a file's faces. A face at the same place in the same chunk as before keeps its
    /// person, so re-indexing a file keeps the names the user gave. Must run inside a transaction.
    func writeFaces(of fileID: FileID, chunks: [ChunkWrite]) throws {
        let previous = try db.query(
            "SELECT ordinal, x, y, width, height, person_id FROM faces WHERE file_id = ? AND person_id IS NOT NULL",
            [.int(fileID.rawValue)]
        ) { row in
            (
                ordinal: Int(row.int(0)), box: CGRect(x: row.double(1), y: row.double(2), width: row.double(3), height: row.double(4)),
                person: PersonID(row.int(5))
            )
        }
        try db.run("DELETE FROM faces WHERE file_id = ?", [.int(fileID.rawValue)])
        for chunk in chunks {
            for face in chunk.faces {
                let person =
                    face.person
                    ?? previous.first { $0.ordinal == chunk.ordinal && Self.overlap($0.box, face.box) >= 0.5 }?.person
                try db.run(
                    """
                    INSERT INTO faces(file_id, ordinal, x, y, width, height, quality, thumb, print, person_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .int(fileID.rawValue), SQLValue(chunk.ordinal), .double(face.box.minX), .double(face.box.minY),
                        .double(face.box.width), .double(face.box.height), .double(Double(face.quality)), SQLValue(face.thumbnail),
                        .blob(VectorCodec.encode(face.print)), person.map { .int($0.rawValue) } ?? .null,
                    ]
                )
            }
        }
    }

    /// A file's faces as writes, keyed by chunk ordinal (for copying an identical file).
    func faceWrites(of fileID: FileID) throws -> [Int: [FaceWrite]] {
        let rows = try db.query(
            "SELECT ordinal, x, y, width, height, quality, thumb, print, person_id FROM faces WHERE file_id = ? ORDER BY id",
            [.int(fileID.rawValue)]
        ) { row -> (Int, FaceWrite)? in
            guard let print = row.blob(7) else { return nil }
            return (
                Int(row.int(0)),
                FaceWrite(
                    box: CGRect(x: row.double(1), y: row.double(2), width: row.double(3), height: row.double(4)),
                    quality: Float(row.double(5)), print: VectorCodec.decode(print), thumbnail: row.text(6),
                    person: row.isNull(8) ? nil : PersonID(row.int(8))
                )
            )
        }
        return Dictionary(grouping: rows.compactMap { $0 }, by: \.0).mapValues { $0.map(\.1) }
    }

    /// Intersection over union of two boxes.
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let shared = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - shared
        return union > 0 ? shared / union : 0
    }

    /// Groups faces not yet assigned to a person: each joins the closest person or starts a new
    /// one, and people that turn out to be one are merged. Returns how many faces were assigned.
    @discardableResult
    public func clusterFaces(_ template: FaceClusters = FaceClusters()) throws -> Int {
        let pending = try db.query("SELECT id, print FROM faces WHERE person_id IS NULL ORDER BY quality DESC") { row in
            (id: row.int(0), print: row.blob(1).map(VectorCodec.decode) ?? [])
        }.filter { !$0.print.isEmpty }
        guard !pending.isEmpty else { return 0 }

        var clusters = template
        _ = try db.query(
            "SELECT f.person_id, p.name IS NOT NULL, f.print FROM faces f JOIN people p ON p.id = f.person_id ORDER BY f.person_id"
        ) { row in
            if let print = row.blob(2) {
                _ = clusters.seed(person: PersonID(row.int(0)), isNamed: row.int(1) != 0, print: VectorCodec.decode(print))
            }
        }
        var touched: Set<Int> = []
        let assigned = pending.map { face -> (id: Int64, group: Int) in
            let group = clusters.assign(face.print)
            touched.insert(group)
            return (face.id, group)
        }
        let merges = clusters.mergeClose(touched)

        try save(clusters, merges: merges, assigned: assigned)
        return assigned.count
    }

    /// Writes a clustering run: new people, merged people and each pending face's person.
    private func save(
        _ clusters: FaceClusters, merges: [(from: Int, into: Int)], assigned: [(id: Int64, group: Int)]
    ) throws {
        try db.transaction {
            var people: [Int: PersonID] = [:]
            func person(for index: Int) throws -> PersonID {
                let root = clusters.resolve(index)
                if let existing = people[root] ?? clusters.groups[root].person { return existing }
                try db.run("INSERT INTO people(created_at) VALUES (?)", [SQLValue(now())])
                let created = PersonID(db.lastInsertRowID)
                people[root] = created
                return created
            }
            for merge in merges {
                guard let absorbed = clusters.groups[merge.from].person else { continue }
                let into = try person(for: merge.into)
                guard absorbed != into else { continue }
                try db.run("UPDATE faces SET person_id = ? WHERE person_id = ?", [.int(into.rawValue), .int(absorbed.rawValue)])
                try db.run("DELETE FROM people WHERE id = ?", [.int(absorbed.rawValue)])
            }
            for face in assigned {
                try db.run(
                    "UPDATE faces SET person_id = ? WHERE id = ?", [.int(try person(for: face.group).rawValue), .int(face.id)])
            }
            try deleteEmptyPeople()
        }
    }

    /// Names a person, or clears the name with `nil`. Naming a person like someone already
    /// named merges the two, which is how the user fixes a person split in two. Returns the
    /// person that now holds the faces.
    @discardableResult
    public func renamePerson(_ id: PersonID, to name: String?) throws -> PersonID {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmed?.isEmpty == false ? trimmed : nil
        return try db.transaction {
            if let newName,
                let other = try db.scalarInt(
                    "SELECT id FROM people WHERE name = ? COLLATE NOCASE AND id != ? LIMIT 1", [.text(newName), .int(id.rawValue)])
            {
                try db.run("UPDATE faces SET person_id = ? WHERE person_id = ?", [.int(other), .int(id.rawValue)])
                try db.run("DELETE FROM people WHERE id = ?", [.int(id.rawValue)])
                return PersonID(other)
            }
            try db.run("UPDATE people SET name = ? WHERE id = ?", [SQLValue(newName), .int(id.rawValue)])
            return id
        }
    }

    /// Sends photos and videos back to the queue so faces are found in files indexed before
    /// faces existed, and clears the backfill flag.
    public func requeueForFaces() throws -> Int {
        try db.transaction {
            try db.run("UPDATE files SET status = 0, attempts = 0 WHERE status = 1 AND kind IN ('image', 'video')")
            let count = db.changes
            try db.run("DELETE FROM settings WHERE key = ?", [.text(Self.facesBackfillKey)])
            return count
        }
    }

    /// Unnamed people left without faces (their files were deleted or re-indexed differently).
    /// Named ones stay, so the name is still there if their faces come back.
    func deleteEmptyPeople() throws {
        try db.run("DELETE FROM people WHERE name IS NULL AND NOT EXISTS (SELECT 1 FROM faces WHERE person_id = people.id)")
    }
}

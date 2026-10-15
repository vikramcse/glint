import Foundation
import GlintCore

/// Ordered schema migrations. Never edit a shipped migration; append a new one.
/// Archived databases from every shipped version are upgraded in `MigrationTests`.
enum Schema {
    static let migrations: [String] = [
        // v1
        """
        CREATE TABLE sources(
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            bookmark BLOB,
            added_at REAL NOT NULL
        );
        CREATE TABLE files(
            id INTEGER PRIMARY KEY,
            source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            path TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            uti TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified REAL NOT NULL,
            content_hash TEXT,
            status INTEGER NOT NULL DEFAULT 0,
            priority INTEGER NOT NULL DEFAULT 0,
            attempts INTEGER NOT NULL DEFAULT 0,
            error TEXT,
            indexed_at REAL,
            space TEXT,
            duration REAL,
            waveform BLOB
        );
        CREATE INDEX files_queue ON files(status, priority, modified DESC);
        CREATE INDEX files_hash ON files(content_hash);
        CREATE INDEX files_source ON files(source_id);
        CREATE INDEX files_kind ON files(kind, status, modified DESC);

        CREATE TABLE chunks(
            id INTEGER PRIMARY KEY,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            locator TEXT NOT NULL,
            text TEXT,
            thumb TEXT
        );
        CREATE INDEX chunks_file ON chunks(file_id, ordinal);

        CREATE VIRTUAL TABLE chunks_fts USING fts5(
            text, content='chunks', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER chunks_ai AFTER INSERT ON chunks WHEN new.text IS NOT NULL BEGIN
            INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER chunks_ad AFTER DELETE ON chunks WHEN old.text IS NOT NULL BEGIN
            INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
        END;

        CREATE VIRTUAL TABLE names_fts USING fts5(
            name, content='files', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER files_ai AFTER INSERT ON files BEGIN
            INSERT INTO names_fts(rowid, name) VALUES (new.id, new.name);
        END;
        CREATE TRIGGER files_ad AFTER DELETE ON files BEGIN
            INSERT INTO names_fts(names_fts, rowid, name) VALUES ('delete', old.id, old.name);
        END;
        CREATE TRIGGER files_au AFTER UPDATE OF name ON files BEGIN
            INSERT INTO names_fts(names_fts, rowid, name) VALUES ('delete', old.id, old.name);
            INSERT INTO names_fts(rowid, name) VALUES (new.id, new.name);
        END;

        CREATE TABLE vectors(
            chunk_id INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
            file_id INTEGER NOT NULL,
            space TEXT NOT NULL,
            data BLOB NOT NULL
        );
        CREATE INDEX vectors_space ON vectors(space, chunk_id);
        CREATE INDEX vectors_file ON vectors(file_id);

        CREATE TABLE saved_searches(
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            query TEXT NOT NULL,
            filter TEXT,
            created_at REAL NOT NULL
        );

        CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """,
        // v2: faces and the people they are grouped into. Photos and videos indexed before this
        // have no faces; the People view offers to rescan them (`faces_backfill`). Safe to run
        // again: see `repairFaces`.
        """
        CREATE TABLE IF NOT EXISTS people(
            id INTEGER PRIMARY KEY,
            name TEXT,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS faces(
            id INTEGER PRIMARY KEY,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            x REAL NOT NULL,
            y REAL NOT NULL,
            width REAL NOT NULL,
            height REAL NOT NULL,
            quality REAL NOT NULL,
            thumb TEXT,
            print BLOB NOT NULL,
            person_id INTEGER REFERENCES people(id) ON DELETE SET NULL
        );
        CREATE INDEX IF NOT EXISTS faces_file ON faces(file_id, ordinal);
        CREATE INDEX IF NOT EXISTS faces_person ON faces(person_id);
        INSERT OR IGNORE INTO settings(key, value)
            SELECT 'faces_backfill', 'needed' WHERE EXISTS (SELECT 1 FROM files WHERE kind IN ('image', 'video'));
        """,
    ]

    static var currentVersion: Int { migrations.count }

    static func migrate(_ connection: SQLiteConnection) throws {
        let version = Int(try connection.scalarInt("PRAGMA user_version") ?? 0)
        guard version < currentVersion else {
            try repairFaces(connection, version: version)
            return
        }
        for index in version..<currentVersion {
            do {
                try connection.transaction {
                    try connection.execute(migrations[index])
                    try connection.execute("PRAGMA user_version = \(index + 1)")
                }
                Log.store.info("Migrated index to schema v\(index + 1, privacy: .public)")
            } catch {
                throw StoreError.migration(version: index + 1, message: String(describing: error))
            }
        }
    }
}

extension Schema {
    /// A development build of a reverted change (visual tags, 819d9bc) also numbered its
    /// migration v2, so a database can report v2 without the faces tables; every photo commit
    /// then fails. Re-applies v2 when its tables are missing.
    static func repairFaces(_ connection: SQLiteConnection, version: Int) throws {
        guard version >= 2,
            try connection.scalarInt("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'faces'") == nil
        else { return }
        do {
            try connection.transaction { try connection.execute(migrations[1]) }
            Log.store.info("Added the faces tables missing from a schema v2 index")
        } catch {
            throw StoreError.migration(version: 2, message: String(describing: error))
        }
    }
}

/// Processing state of a file row.
public enum FileStatus: Int, Sendable, Codable {
    case pending = 0
    case indexed = 1
    case failed = 2
}

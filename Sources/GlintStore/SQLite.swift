import Foundation
import GlintCore
import SQLite3

/// Errors from the store. Messages never include paths or query text.
public enum StoreError: GlintError, Equatable {
    case open(code: Int32)
    case sqlite(code: Int32, message: String)
    case migration(version: Int, message: String)
    case corrupt

    public var category: ErrorCategory {
        switch self {
        case .corrupt: .corrupt
        case .open(let code) where code == SQLITE_PERM || code == SQLITE_CANTOPEN: .permissionDenied
        default: .storage
        }
    }

    public var description: String {
        switch self {
        case .open(let code): "Could not open the index (SQLite \(code))"
        case .sqlite(let code, let message): "SQLite \(code): \(message)"
        case .migration(let version, let message): "Migration \(version) failed: \(message)"
        case .corrupt: "The index is corrupt"
        }
    }
}

/// A value bound to or read from a statement.
enum SQLValue: Sendable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

extension SQLValue {
    init(_ value: Int) { self = .int(Int64(value)) }
    init(_ value: Int64) { self = .int(value) }
    init(_ value: Date) { self = .double(value.timeIntervalSince1970) }
    init(_ value: String?) { self = value.map(SQLValue.text) ?? .null }
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One row of a result set. Only valid inside the row closure.
struct Row {
    fileprivate let statement: OpaquePointer

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func date(_ column: Int32) -> Date { Date(timeIntervalSince1970: double(column)) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

    func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    func blob(_ column: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: pointer, count: count)
    }
}

/// A single SQLite connection. Not thread-safe: each instance is owned by exactly one actor.
final class SQLiteConnection {
    private let handle: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]

    init(url: URL, readOnly: Bool = false) throws {
        var pointer: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
            | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(url.path, &pointer, flags, nil)
        guard code == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw StoreError.open(code: code)
        }
        handle = pointer
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA foreign_keys = ON")
        if !readOnly {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
        }
        try execute("PRAGMA temp_store = MEMORY")
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &error)
        if code != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw StoreError.sqlite(code: code, message: message)
        }
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ arguments: [SQLValue] = []) throws {
        let statement = try prepared(sql, arguments)
        defer { sqlite3_reset(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw error(code) }
    }

    /// Runs a query and maps each row.
    func query<T>(_ sql: String, _ arguments: [SQLValue] = [], map: (Row) throws -> T) throws -> [T] {
        let statement = try prepared(sql, arguments)
        defer { sqlite3_reset(statement) }
        var results: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw error(code) }
            results.append(try map(Row(statement: statement)))
        }
        return results
    }

    func scalarInt(_ sql: String, _ arguments: [SQLValue] = []) throws -> Int64? {
        try query(sql, arguments) { $0.isNull(0) ? nil : $0.int(0) }.first ?? nil
    }

    /// Runs `body` in an immediate transaction, rolling back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepared(_ sql: String, _ arguments: [SQLValue]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
            sqlite3_clear_bindings(statement)
        } else {
            var pointer: OpaquePointer?
            let code = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &pointer, nil)
            guard code == SQLITE_OK, let pointer else { throw error(code) }
            statements[sql] = pointer
            statement = pointer
        }
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch argument {
            case .null: code = sqlite3_bind_null(statement, index)
            case .int(let value): code = sqlite3_bind_int64(statement, index, value)
            case .double(let value): code = sqlite3_bind_double(statement, index, value)
            case .text(let value): code = sqlite3_bind_text(statement, index, value, -1, transientDestructor)
            case .blob(let value):
                code = value.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transientDestructor)
                }
            }
            guard code == SQLITE_OK else { throw error(code) }
        }
        return statement
    }

    private func error(_ code: Int32) -> StoreError {
        if code == SQLITE_CORRUPT || code == SQLITE_NOTADB { return .corrupt }
        return .sqlite(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}

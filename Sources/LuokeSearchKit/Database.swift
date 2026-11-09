import Foundation
import SQLite3

/// A value bound to a statement's `?`.
public enum SQLValue: Sendable {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

/// One row of a result, read by column index.
public struct Row {
    let statement: OpaquePointer

    public func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    public func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    public func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

    public func text(_ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: bytes)
    }

    public func blob(_ column: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard let bytes = sqlite3_column_blob(statement, column) else { return count == 0 ? nil : Data() }
        return Data(bytes: bytes, count: count)
    }
}

/// A thin wrapper over the system's SQLite (which has FTS5 with the trigram tokenizer). One connection, used from one
/// thread at a time; WAL lets a search read while an indexer writes from another process.
public final class Database {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    private var handle: OpaquePointer?
    public let path: String

    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            // No path in it: `index --job`'s stderr goes into luoke-core's diagnostics (review A-22).
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw Failure(message: "can't open the index: \(message)")
        }
        // Another process may be opening the same new file (review A-18): wait for its locks. Switching to WAL
        // doesn't wait on the busy handler while others have it open, so that is tried again for a while.
        sqlite3_busy_timeout(handle, 5000)
        for attempt in 1...50 {
            do {
                try execute("PRAGMA journal_mode = WAL")
                break
            } catch let failure as Failure where failure.message.contains("locked") && attempt < 50 {
                usleep(100_000)
            }
        }
        try execute("""
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            """)
    }

    deinit { sqlite3_close_v2(handle) }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "error"
            sqlite3_free(error)
            throw Failure(message: message)
        }
    }

    /// Runs `sql` with `values`, calling `row` for each result row.
    public func query(_ sql: String, _ values: [SQLValue] = [], _ row: (Row) throws -> Void = { _ in }) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { try row(Row(statement: statement)); continue }
            if step == SQLITE_DONE { return }
            throw failure()
        }
    }

    /// Runs `sql` once per set of values with one prepared statement (bulk inserts).
    public func run(_ sql: String, _ valueSets: [[SQLValue]]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for values in valueSets {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind(values, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        }
    }

    public var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }

    /// Runs `body` in one transaction; rolls back if it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
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

    public func scalarInt(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        var value: Int64 = 0
        try query(sql, values) { value = $0.int(0) }
        return value
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure()
        }
        return statement
    }

    private func bind(_ values: [SQLValue], to statement: OpaquePointer) throws {
        // SQLite copies text and blobs right away with SQLITE_TRANSIENT.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .int(let number): result = sqlite3_bind_int64(statement, index, number)
            case .double(let number): result = sqlite3_bind_double(statement, index, number)
            // By its length in bytes: a NUL inside doesn't end it (review A-15).
            case .text(let text): result = sqlite3_bind_text(statement, index, text, Int32(text.utf8.count), transient)
            case .blob(let data):
                result = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
                }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw failure() }
        }
    }

    private func failure() -> Failure {
        Failure(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "error")
    }
}

import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    var description: String { "SQLite error \(code): \(message)" }
}

enum SQLValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

/// This tells SQLite to copy bound buffers because Swift may free them right after the call.
private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The owner confines a single SQLite connection to one queue because the connection is not
/// thread-safe.
final class Database {
    private let handle: OpaquePointer

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close_v2(db)
            throw SQLiteError(code: rc, message: message)
        }
        handle = db
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard rc == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorPointer)
            throw SQLiteError(code: rc, message: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            throw SQLiteError(code: rc, message: lastErrorMessage)
        }
        return Statement(handle: statement, database: self)
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(values)
        while try statement.step() {}
    }

    /// Runs a query and maps every row.
    func query<T>(_ sql: String, _ values: [SQLValue] = [], map: (Statement) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(values)
        var rows: [T] = []
        while try statement.step() {
            rows.append(try map(statement))
        }
        return rows
    }

    func scalarInt(_ sql: String, _ values: [SQLValue] = []) throws -> Int64? {
        try query(sql, values) { $0.int64(0) }.first
    }

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

    func userVersion() throws -> Int {
        Int(try scalarInt("PRAGMA user_version") ?? 0)
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    fileprivate var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }
}

final class Statement {
    private let handle: OpaquePointer
    private let database: Database

    fileprivate init(handle: OpaquePointer, database: Database) {
        self.handle = handle
        self.database = database
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(handle, index)
            case .int(let number):
                rc = sqlite3_bind_int64(handle, index, number)
            case .double(let number):
                rc = sqlite3_bind_double(handle, index, number)
            case .text(let string):
                rc = sqlite3_bind_text(handle, index, string, -1, transientDestructor)
            case .blob(let data):
                if data.isEmpty {
                    rc = sqlite3_bind_zeroblob(handle, index, 0)
                } else {
                    rc = data.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), transientDestructor)
                    }
                }
            }
            guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: database.lastErrorMessage) }
        }
    }

    /// This makes the statement ready to run again with new bindings.
    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    /// It advances one row. It returns false once the statement is done.
    func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(code: rc, message: database.lastErrorMessage)
        }
    }

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(handle, column) == SQLITE_NULL
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }

    func string(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: text)
    }

    func data(_ column: Int32) -> Data? {
        guard !isNull(column) else { return nil }
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let bytes = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

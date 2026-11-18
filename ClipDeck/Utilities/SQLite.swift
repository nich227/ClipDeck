import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    var description: String { "SQLite error \(code): \(message)" }
}

extension SQLiteError: LocalizedError {
    /// Describe what went wrong in words a person can act on, and include what SQLite reported.
    var errorDescription: String? {
        let problem: String
        switch primaryCode {
        case SQLITE_FULL:
            problem = "The disk is full, so the history can't be saved"
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            problem = "The history database is damaged"
        case SQLITE_IOERR:
            problem = "ClipDeck encountered a disk error while reading or saving the history"
        case SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_READONLY, SQLITE_AUTH:
            problem = "ClipDeck can't open or change the files in its history folder"
        case SQLITE_BUSY, SQLITE_LOCKED:
            problem = "Another app is using the history database"
        case SQLITE_NOMEM:
            problem = "There isn't enough memory to read the history"
        default:
            problem = "The history database reported an error"
        }
        return "\(problem) (\(description))."
    }

    var recoverySuggestion: String? {
        switch primaryCode {
        case SQLITE_FULL:
            return "Free some space on the disk."
        case SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_READONLY, SQLITE_AUTH:
            return "Check the permissions of the folder."
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return "Quit ClipDeck. Move the ClipDeck folder from ~/Library/Application Support to another folder "
                + "to start with an empty history."
        default:
            return nil
        }
    }

    /// The low byte of an extended result code is its primary code.
    private var primaryCode: Int32 { code & 0xFF }
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
    /// The `run`, `query`, and `first` methods compile each statement once and reuse it. Its SQL is
    /// the key.
    private var cache: [String: Statement] = [:]

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
        cache.removeAll()
        sqlite3_close_v2(handle)
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    var cachedStatementCount: Int { cache.count }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard rc == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorPointer)
            throw SQLiteError(code: rc, message: message)
        }
    }

    /// Compiles a statement that the caller owns. `persistent` hints to SQLite that the caller
    /// keeps and reuses the statement.
    func prepare(_ sql: String, persistent: Bool = false) throws -> Statement {
        var statement: OpaquePointer?
        let flags = persistent ? UInt32(SQLITE_PREPARE_PERSISTENT) : 0
        let rc = sqlite3_prepare_v3(handle, sql, -1, flags, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            throw SQLiteError(code: rc, message: lastErrorMessage)
        }
        return Statement(handle: statement)
    }

    /// The statement was compiled for this SQL earlier, or it is new. If a row mapper runs the same
    /// SQL while the statement is still stepping, it receives a different statement.
    private func cached(_ sql: String) throws -> Statement {
        if let statement = cache[sql] {
            if !statement.isBusy { return statement }
            return try prepare(sql)
        }
        let statement = try prepare(sql, persistent: true)
        cache[sql] = statement
        return statement
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try cached(sql)
        try statement.withBorrowedBindings(values) {
            while try statement.step() {}
        }
    }

    /// Runs a query and maps every row.
    func query<T>(_ sql: String, _ values: [SQLValue] = [], map: (Statement) throws -> T) throws -> [T] {
        let statement = try cached(sql)
        return try statement.withBorrowedBindings(values) {
            var rows: [T] = []
            while try statement.step() {
                rows.append(try map(statement))
            }
            return rows
        }
    }

    /// Runs a query and maps its first row. The statement still runs to completion, so a write
    /// with a RETURNING clause changes every row it matches.
    func first<T>(_ sql: String, _ values: [SQLValue] = [], map: (Statement) throws -> T) throws -> T? {
        let statement = try cached(sql)
        return try statement.withBorrowedBindings(values) {
            guard try statement.step() else { return nil }
            let row = try map(statement)
            while try statement.step() {}
            return row
        }
    }

    func scalarInt(_ sql: String, _ values: [SQLValue] = []) throws -> Int64? {
        try first(sql, values) { $0.int64(0) }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try run("COMMIT")
            return result
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    func userVersion() throws -> Int {
        Int(try scalarInt("PRAGMA user_version") ?? 0)
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    /// Reads the first bytes of a text or blob column without loading the rest of the value. It
    /// returns nil when the row does not exist or the column holds NULL.
    func prefix(ofColumn column: String, inTable table: String, rowID: Int64, maxBytes: Int) throws -> Data? {
        var blob: OpaquePointer?
        guard sqlite3_blob_open(handle, "main", table, column, rowID, 0, &blob) == SQLITE_OK, let blob else {
            sqlite3_blob_close(blob)
            return nil
        }
        defer { sqlite3_blob_close(blob) }
        let count = min(Int(sqlite3_blob_bytes(blob)), maxBytes)
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let rc = data.withUnsafeMutableBytes { sqlite3_blob_read(blob, $0.baseAddress, Int32(count), 0) }
        guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: lastErrorMessage) }
        return data
    }

    private var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }
}

final class Statement {
    private let handle: OpaquePointer

    fileprivate init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_finalize(handle)
    }

    private var lastErrorMessage: String { String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))) }

    fileprivate var isBusy: Bool { sqlite3_stmt_busy(handle) != 0 }

    private func check(_ rc: Int32) throws {
        guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: lastErrorMessage) }
    }

    /// This binds copies of the values, so the statement can run after the values are gone.
    func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null:
                try check(sqlite3_bind_null(handle, index))
            case .int(let number):
                try check(sqlite3_bind_int64(handle, index, number))
            case .double(let number):
                try check(sqlite3_bind_double(handle, index, number))
            case .text(var string):
                try check(string.withUTF8 { bindText($0, at: index, destructor: transientDestructor) })
            case .blob(let data):
                try check(data.withUnsafeBytes { buffer in
                    buffer.isEmpty
                        ? sqlite3_bind_zeroblob(handle, index, 0)
                        : sqlite3_bind_blob64(handle, index, buffer.baseAddress, UInt64(buffer.count), transientDestructor)
                })
            }
        }
    }

    /// Binds the values without copying their bytes, runs `body`, and resets the statement. The
    /// statement reads text and blobs straight from the Swift buffers, which stay alive until
    /// `body` returns. Do not step the statement after this call returns.
    fileprivate func withBorrowedBindings<T>(_ values: [SQLValue], _ body: () throws -> T) throws -> T {
        defer { reset() }
        return try borrow(values, from: 0, body)
    }

    private func borrow<T>(_ values: [SQLValue], from offset: Int, _ body: () throws -> T) throws -> T {
        guard offset < values.count else { return try body() }
        let index = Int32(offset + 1)
        switch values[offset] {
        case .null:
            try check(sqlite3_bind_null(handle, index))
        case .int(let number):
            try check(sqlite3_bind_int64(handle, index, number))
        case .double(let number):
            try check(sqlite3_bind_double(handle, index, number))
        case .text(var string):
            return try string.withUTF8 { buffer in
                try check(bindText(buffer, at: index, destructor: nil))
                return try borrow(values, from: offset + 1, body)
            }
        case .blob(let data):
            return try data.withUnsafeBytes { buffer in
                try check(buffer.isEmpty
                    ? sqlite3_bind_zeroblob(handle, index, 0)
                    : sqlite3_bind_blob64(handle, index, buffer.baseAddress, UInt64(buffer.count), nil))
                return try borrow(values, from: offset + 1, body)
            }
        }
        return try borrow(values, from: offset + 1, body)
    }

    /// Passing the length explicitly lets text keep any NUL characters it contains.
    private func bindText(_ buffer: UnsafeBufferPointer<UInt8>, at index: Int32, destructor: sqlite3_destructor_type?) -> Int32 {
        // An empty buffer may have no address, and a null address would bind NULL.
        guard let base = buffer.baseAddress, !buffer.isEmpty else {
            return sqlite3_bind_text(handle, index, "", 0, transientDestructor)
        }
        return base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
            sqlite3_bind_text64(handle, index, $0, UInt64(buffer.count), destructor, UInt8(SQLITE_UTF8))
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
        default: throw SQLiteError(code: rc, message: lastErrorMessage)
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
        let count = Int(sqlite3_column_bytes(handle, column))
        return String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
    }

    func data(_ column: Int32) -> Data? {
        guard !isNull(column) else { return nil }
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let bytes = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

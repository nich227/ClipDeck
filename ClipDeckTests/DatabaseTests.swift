import SQLite3
import XCTest
@testable import ClipDeck

final class DatabaseTests: XCTestCase {
    private var directory: URL!
    private var db: Database!

    override func setUpWithError() throws {
        directory = Fixtures.temporaryDirectory()
        db = try Database(path: directory.appendingPathComponent("test.sqlite").path)
        try db.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT UNIQUE, payload BLOB)")
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testRepeatedSQLIsCompiledOnce() throws {
        let before = db.cachedStatementCount
        for index in 0..<5 {
            try db.run("INSERT INTO notes (body) VALUES (?)", [.text("note \(index)")])
        }
        XCTAssertEqual(db.cachedStatementCount, before + 1)
        let bodies = try db.query("SELECT body FROM notes ORDER BY id") { $0.string(0) ?? "" }
        XCTAssertEqual(bodies, (0..<5).map { "note \($0)" })
    }

    func testBoundTextAndBlobsRoundTrip() throws {
        let large = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
        let rows: [(String, Data)] = [
            ("plain", Data([1, 2, 3])),
            ("", Data()),
            ("before\u{0}after", large),
            ("caf\u{E9} \u{1F4CE}", Data([0])),
        ]
        for (body, payload) in rows {
            try db.run("INSERT INTO notes (body, payload) VALUES (?, ?)", [.text(body), .blob(payload)])
        }
        let stored = try db.query("SELECT body, payload, body IS NULL, payload IS NULL FROM notes ORDER BY id") {
            ($0.string(0), $0.data(1), $0.int64(2), $0.int64(3))
        }
        XCTAssertEqual(stored.map(\.0), rows.map(\.0))
        XCTAssertEqual(stored.map(\.1), rows.map(\.1))
        XCTAssertEqual(stored.map(\.2), [0, 0, 0, 0], "an empty string is stored as text, not as NULL")
        XCTAssertEqual(stored.map(\.3), [0, 0, 0, 0], "an empty blob is stored as a blob, not as NULL")
    }

    func testBorrowedBindingsReadSlicesBridgedValuesAndShortStrings() throws {
        let whole = Data("xxhelloxx".utf8)
        let bridged = NSData(bytes: [UInt8](repeating: 7, count: 40_000), length: 40_000) as Data
        let pieces = NSMutableData(data: Data("first ".utf8))
        pieces.append(Data("second".utf8))
        // A string that Foundation stores as UTF-16 has no UTF-8 buffer until it is asked for one.
        let foreign = NSString(string: "caf\u{E9} \u{65E5}\u{672C}\u{8A9E} " + String(repeating: "\u{1F4CE}", count: 2_000)) as String
        let rows: [(String, Data)] = [
            ("slice", whole[2..<7]),
            ("empty slice", whole[4..<4]),
            ("bridged", bridged),
            ("mutable", pieces as Data),
            (foreign, Data([1])),
            ("tiny", Data([9])),
            (String(repeating: "long ", count: 10_000), Data(repeating: 3, count: 15)),
        ]
        for (body, payload) in rows {
            try db.run("INSERT INTO notes (body, payload) VALUES (?, ?)", [.text(body), .blob(payload)])
        }
        let stored = try db.query("SELECT body, payload FROM notes ORDER BY id") { ($0.string(0), $0.data(1)) }
        XCTAssertEqual(stored.map(\.0), rows.map(\.0))
        XCTAssertEqual(stored.map(\.1), rows.map { Data($0.1) })
        // A comparison finds the rows again when it binds the same values.
        for (body, payload) in rows {
            let found = try db.first("SELECT 1 FROM notes WHERE body = ? AND payload = ?", [.text(body), .blob(payload)]) { _ in true }
            XCTAssertEqual(found, true, String(body.prefix(12)))
        }
    }

    func testAMapperThatThrowsLeavesTheStatementReady() throws {
        struct Stop: Error {}
        for body in ["a", "b", "c"] {
            try db.run("INSERT INTO notes (body) VALUES (?)", [.text(body)])
        }
        let sql = "SELECT body FROM notes WHERE id >= ? ORDER BY id"
        let before = db.cachedStatementCount
        XCTAssertThrowsError(try db.query(sql, [.int(1)]) { _ -> String in throw Stop() })
        XCTAssertThrowsError(try db.first(sql, [.int(1)]) { _ -> String in throw Stop() })
        XCTAssertEqual(try db.query(sql, [.int(2)]) { $0.string(0) ?? "" }, ["b", "c"])
        XCTAssertEqual(db.cachedStatementCount, before + 1)
        // A statement that is still open does not block a write after the failed reads.
        try db.transaction { try db.run("DELETE FROM notes WHERE body = ?", [.text("a")]) }
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM notes"), 2)
    }

    func testNestedUseOfOneStatementDoesNotGrowTheCache() throws {
        for body in ["a", "b", "c"] {
            try db.run("INSERT INTO notes (body) VALUES (?)", [.text(body)])
        }
        let sql = "SELECT body FROM notes WHERE id >= ? ORDER BY id"
        _ = try db.query(sql, [.int(1)]) { $0.string(0) }
        let before = db.cachedStatementCount
        for _ in 0..<50 {
            let nested = try db.query(sql, [.int(1)]) { row -> String in
                let inner = try self.db.first(sql, [.int(2)]) { $0.string(0) ?? "" }
                return (row.string(0) ?? "") + (inner ?? "")
            }
            XCTAssertEqual(nested, ["ab", "bb", "cb"])
        }
        XCTAssertEqual(db.cachedStatementCount, before)
    }

    func testAFailedStatementInsideATransactionRollsEverythingBack() throws {
        try db.run("INSERT INTO notes (body) VALUES ('kept')")
        XCTAssertThrowsError(try db.transaction {
            try db.run("INSERT INTO notes (body) VALUES ('lost')")
            try db.run("INSERT INTO notes (body) VALUES ('kept')")
        }) { error in
            XCTAssertEqual((error as? SQLiteError)?.code, SQLITE_CONSTRAINT)
        }
        XCTAssertEqual(try db.query("SELECT body FROM notes") { $0.string(0) ?? "" }, ["kept"])
        try db.transaction { try db.run("INSERT INTO notes (body) VALUES ('next')") }
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM notes"), 2)
    }

    func testCopiedBindingsRoundTripOnAnOwnedStatement() throws {
        let insert = try db.prepare("INSERT INTO notes (body, payload) VALUES (?, ?)")
        for body in ["", "before\u{0}after"] {
            insert.reset()
            try insert.bind([.text(body), .blob(Data(body.utf8))])
            while try insert.step() {}
        }
        let stored = try db.query("SELECT body, payload FROM notes ORDER BY id") { ($0.string(0), $0.data(1)) }
        XCTAssertEqual(stored.map(\.0), ["", "before\u{0}after"])
        XCTAssertEqual(stored.map(\.1), [Data(), Data("before\u{0}after".utf8)])
    }

    func testAStatementThatFailedRunsAgain() throws {
        let sql = "INSERT INTO notes (body) VALUES (?)"
        try db.run(sql, [.text("once")])
        XCTAssertThrowsError(try db.run(sql, [.text("once")]))
        try db.run(sql, [.text("twice")])
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM notes"), 2)
    }

    func testARowMapperCanRunTheSameSQL() throws {
        for body in ["a", "b", "c"] {
            try db.run("INSERT INTO notes (body) VALUES (?)", [.text(body)])
        }
        let sql = "SELECT body FROM notes WHERE id >= ? ORDER BY id"
        let nested = try db.query(sql, [.int(1)]) { row -> String in
            let inner = try self.db.query(sql, [.int(3)]) { $0.string(0) ?? "" }
            return (row.string(0) ?? "") + inner.joined()
        }
        XCTAssertEqual(nested, ["ac", "bc", "cc"])
    }

    func testFirstRunsAWriteToCompletion() throws {
        for body in ["a", "b", "c"] {
            try db.run("INSERT INTO notes (body) VALUES (?)", [.text(body)])
        }
        let returned = try db.first("UPDATE notes SET payload = x'01' RETURNING id") { $0.int64(0) }
        XCTAssertNotNil(returned)
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM notes WHERE payload IS NOT NULL"), 3)
        XCTAssertNil(try db.first("SELECT id FROM notes WHERE body = ?", [.text("missing")]) { $0.int64(0) })
    }

    func testAFailedTransactionRollsBackAndTheNextOneCommits() throws {
        struct Stop: Error {}
        XCTAssertThrowsError(try db.transaction {
            try db.run("INSERT INTO notes (body) VALUES ('lost')")
            throw Stop()
        })
        try db.transaction { try db.run("INSERT INTO notes (body) VALUES ('kept')") }
        let bodies = try db.query("SELECT body FROM notes") { $0.string(0) ?? "" }
        XCTAssertEqual(bodies, ["kept"])
    }

    func testPrefixReadsTheStartOfAColumn() throws {
        let body = String(repeating: "0123456789", count: 50_000)
        try db.run("INSERT INTO notes (id, body, payload) VALUES (7, ?, NULL)", [.text(body)])
        try db.run("INSERT INTO notes (id, body) VALUES (8, 'short')")
        XCTAssertEqual(try db.prefix(ofColumn: "body", inTable: "notes", rowID: 7, maxBytes: 25), Data("0123456789012345678901234".utf8))
        XCTAssertEqual(try db.prefix(ofColumn: "body", inTable: "notes", rowID: 8, maxBytes: 25), Data("short".utf8))
        XCTAssertEqual(try db.prefix(ofColumn: "body", inTable: "notes", rowID: 8, maxBytes: 0), Data())
        XCTAssertNil(try db.prefix(ofColumn: "body", inTable: "notes", rowID: 99, maxBytes: 25), "no such row")
        XCTAssertNil(try db.prefix(ofColumn: "payload", inTable: "notes", rowID: 7, maxBytes: 25), "the column holds NULL")
        XCTAssertNil(try db.prefix(ofColumn: "nope", inTable: "notes", rowID: 7, maxBytes: 25), "no such column")
    }

    func testAStatementCanBeReleasedAfterItsDatabase() throws {
        var statement: Statement? = try db.prepare("SELECT count(*) FROM notes")
        XCTAssertNotNil(statement)
        db = nil
        statement = nil
        let reopened = try Database(path: directory.appendingPathComponent("test.sqlite").path)
        XCTAssertEqual(try reopened.scalarInt("SELECT count(*) FROM notes"), 0)
    }
}

import XCTest
@testable import ClipDeck

/// The step from schema version 4 to 5 rebuilds a whole history, and a build that stops at
/// version 4 cannot open the result. These tests compare a migrated database with what went in.
final class ClipStoreMigrationTests: XCTestCase {
    private var directory: URL!
    private var location: StoreLocation!

    override func setUpWithError() throws {
        directory = Fixtures.temporaryDirectory()
        location = StoreLocation(root: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Snapshot: Equatable {
        var items: [String]
        var children: [String]
        var totalBytes: Int64?
    }

    private func snapshot(_ db: Database) throws -> Snapshot {
        Snapshot(
            items: try StoreInspector.items(db), children: try StoreInspector.children(db),
            totalBytes: try db.scalarInt(ClipStore.totalBytesSQL)
        )
    }

    private func buildVersionFour(_ rows: [VersionFourFixture.Row]) throws -> Snapshot {
        let db = try VersionFourFixture.open(at: location)
        try db.transaction {
            for row in rows { try VersionFourFixture.insert(row, into: db) }
        }
        XCTAssertEqual(try db.userVersion(), 4)
        return try snapshot(db)
    }

    private func freshSchema() throws -> [String] {
        let other = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: other) }
        let fresh = StoreLocation(root: other)
        _ = try ClipStore(location: fresh)
        return try StoreInspector.schema(try Database(path: fresh.database.path))
    }

    private func expectedOrder(_ rows: [VersionFourFixture.Row]) -> [Int64] {
        rows.sorted { ($0.lastUsed, $0.id) > ($1.lastUsed, $1.id) }.map(\.id)
    }

    private func assertSearches(
        _ store: ClipStore, find rows: [VersionFourFixture.Row], queries: [String], file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let order = expectedOrder(rows)
        let texts = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.decodedText) })
        for query in queries {
            let expected = order.filter { SearchModel.matches(texts[$0] ?? "", query: query) }
            let found = try await store.search(query, limit: 100_000).map(\.id)
            XCTAssertEqual(found, expected, "search for \(query)", file: file, line: line)
            // Short pages use the cursor to walk the same rows.
            var paged: [Int64] = []
            var cursor: PageCursor?
            while true {
                let page = try await store.search(query, after: cursor, limit: 13)
                guard let last = page.last else { break }
                paged += page.map(\.id)
                cursor = PageCursor(after: last)
            }
            XCTAssertEqual(paged, expected, "paged search for \(query)", file: file, line: line)
        }
    }

    private static let queries = ["al", "alpha", "alp be", "beta", "c", "co", "con", "cafe", "naive", "42", "424", "zebra", "tmp txt", "image", "u", "\u{65E5}\u{672C}", "x", "gamma delta"]

    // MARK: - Version 4

    func testEveryRowSurvivesTheMoveToVersionFive() async throws {
        let rows = VersionFourFixture.rows(count: 600)
        let before = try buildVersionFour(rows)
        XCTAssertEqual(before.items.count, 600)
        try FileManager.default.createDirectory(at: location.blobs, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: location.blobURL(for: "hash-9"))

        let store = try ClipStore(location: location)
        let version = try await store.schemaVersionOnDisk()
        XCTAssertEqual(version, 5)
        let db = try Database(path: location.database.path)
        let after = try snapshot(db)
        XCTAssertEqual(after.items, before.items)
        XCTAssertEqual(after.children, before.children)
        XCTAssertEqual(after.totalBytes, before.totalBytes)
        try StoreInspector.assertSound(at: location, "after the migration")
        XCTAssertEqual(try StoreInspector.schema(db), try freshSchema())
        XCTAssertNil(try db.first("SELECT 1 FROM sqlite_master WHERE name = 'items_v5'") { _ in true })
        XCTAssertNil(try db.first("SELECT 1 FROM sqlite_temp_master WHERE name = 'items_order'") { _ in true })

        // The sequence numbers start at 1 and follow the list order.
        let numbers = try db.query("SELECT seq FROM items ORDER BY last_used, id") { $0.int64(0) }
        XCTAssertEqual(numbers, Array(1...600))

        var listed: [ClipItem] = []
        var cursor: PageCursor?
        while true {
            let page = try await store.page(after: cursor, limit: 97)
            guard let last = page.last else { break }
            listed += page
            cursor = PageCursor(after: last)
        }
        XCTAssertEqual(listed.map(\.id), expectedOrder(rows))
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for item in listed {
            let row = try XCTUnwrap(byID[item.id])
            XCTAssertEqual(item.preview, SearchModel.preview(of: row.decodedText), "preview of \(item.id)")
            XCTAssertEqual(item.title, row.title)
            XCTAssertEqual(item.detail, row.detail)
            XCTAssertEqual(item.kind, row.kind)
            XCTAssertEqual(item.fileCount, row.files.count)
            XCTAssertEqual(item.blobType, row.blobType)
            XCTAssertEqual(item.lastUsed, Date(timeIntervalSince1970: row.lastUsed))
            XCTAssertEqual(item.createdAt, Date(timeIntervalSince1970: row.createdAt))
        }
        try await assertSearches(store, find: rows, queries: Self.queries)

        let plain = try await store.payload(for: 1)
        XCTAssertNil(plain?.plainText, "offers_plain_text was 0")
        XCTAssertEqual(plain?.representations, rows[0].representations)
        let nul = try await store.payload(for: 4)
        XCTAssertEqual(nul?.plainText, rows[3].decodedText)
        let image = try await store.payload(for: 9)
        XCTAssertEqual(image?.blob, PasteboardRepresentation(type: PasteboardTypes.png, data: Data([1, 2, 3])))
        XCTAssertEqual(image?.representations.map(\.type), [PasteboardTypes.html], "an undecodable blob rebuilds no TIFF")
        let file = try await store.payload(for: 10)
        XCTAssertEqual(file?.files, rows[9].files)
        let long = try await store.textPreview(for: 3, maxCharacters: 1_000)
        XCTAssertEqual(long, String(rows[2].decodedText.prefix(1_000)))
    }

    func testAMigratedHistoryTakesEveryKindOfWrite() async throws {
        var rows = VersionFourFixture.rows(count: 300)
        _ = try buildVersionFour(rows)
        let store = try ClipStore(location: location)
        let db = try Database(path: location.database.path)
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        // The cases are a new row, a repeat copy of an old row, and a copy from the panel.
        let added = Fixtures.textCapture("alpha added after the move")
        let addedID = try await store.insert(added, at: base).id
        let old = rows[20]
        let repeatCopy = Capture(
            kind: old.kind, hash: old.hash, title: old.title, detail: old.detail, searchText: old.decodedText,
            byteSize: old.byteSize + 11, representations: [PasteboardRepresentation(type: PasteboardTypes.rtf, data: Data("{new}".utf8))],
            offersPlainText: true, files: old.files, blob: nil, offersTIFF: false
        )
        let bumped = try await store.insert(repeatCopy, at: base.addingTimeInterval(1))
        XCTAssertEqual(bumped, .bumped(old.id))
        try await store.touch(id: 5, at: base.addingTimeInterval(2))
        let listed = try await store.page(limit: 4).map(\.id)
        XCTAssertEqual(listed.prefix(3), [5, old.id, addedID])
        let found = try await store.search("beta", limit: 1).map(\.id)
        XCTAssertEqual(found, [5])
        try StoreInspector.assertSound(at: location, "after writes")

        let saved = try await store.saveThumbnail(Fixtures.png(width: 2, height: 2), for: "hash-9")
        XCTAssertTrue(saved)
        try StoreInspector.assertSound(at: location, "after a thumbnail")

        // Removing rows also removes their formats, file references, and index entries.
        let removed = try await store.clear(ClearRequest(range: .allTime, kinds: [.file, .image]))
        XCTAssertEqual(removed, rows.filter { $0.kind != .text }.count)
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM files"), 0)
        try StoreInspector.assertSound(at: location, "after a clear")
        rows.removeAll { $0.kind != .text }
        let used = try await store.storageUsage()
        _ = try await store.setStorageBudget(used / 2)
        try StoreInspector.assertSound(at: location, "after an eviction")
        let left = try await store.storageUsage()
        XCTAssertLessThanOrEqual(left, used / 2)
        let everything = try await store.clear(ClearRequest(range: .allTime, kinds: Set(ClipKind.allCases)))
        XCTAssertGreaterThan(everything, 0)
        try StoreInspector.assertSound(at: location, "after clearing everything")
        XCTAssertEqual(try db.scalarInt(ClipStore.totalBytesSQL), 0)
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM items_fts_docsize"), 0)
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM representations"), 0)
    }

    func testAFailedMoveToVersionFiveLeavesVersionFourIntact() async throws {
        let rows = VersionFourFixture.rows(count: 120)
        let before = try buildVersionFour(rows)
        do {
            // If an index has a name that the step uses, the step fails after replacing the table.
            let db = try Database(path: location.database.path)
            try db.execute("CREATE TABLE blocker (x); CREATE INDEX items_seq ON blocker (x)")
        }

        XCTAssertThrowsError(try ClipStore(location: location)) { error in
            XCTAssertTrue(error is SQLiteError, "\(error)")
        }
        do {
            let db = try Database(path: location.database.path)
            XCTAssertEqual(try db.userVersion(), 4)
            XCTAssertEqual(try snapshot(db), before)
            XCTAssertEqual(try db.query("PRAGMA integrity_check") { $0.string(0) ?? "" }, ["ok"])
            XCTAssertNil(try db.first("PRAGMA foreign_key_check") { _ in true })
            XCTAssertNil(try db.first("SELECT 1 FROM sqlite_master WHERE name = 'items_v5'") { _ in true })
            // The version 4 index and its triggers still work.
            let found = try db.query("SELECT rowid FROM items_fts WHERE items_fts MATCH 'note'") { $0.int64(0) }
            XCTAssertEqual(found, [1])
            try db.execute("PRAGMA foreign_keys = ON")
            try db.run("DELETE FROM items WHERE id = 1")
            XCTAssertNil(try db.first("SELECT rowid FROM items_fts WHERE items_fts MATCH 'note'") { _ in true })
        }

        // The same connection keeps foreign keys on after the failure and after the step runs.
        do {
            let db = try Database(path: location.database.path)
            try ClipStore.configure(db)
            XCTAssertThrowsError(try ClipStore.migrate(db))
            XCTAssertEqual(try db.scalarInt("PRAGMA foreign_keys"), 1)
            XCTAssertEqual(try db.userVersion(), 4)
            try db.execute("DROP TABLE blocker")
            try ClipStore.migrate(db)
            XCTAssertEqual(try db.scalarInt("PRAGMA foreign_keys"), 1)
            XCTAssertEqual(try db.userVersion(), 5)
        }

        let store = try ClipStore(location: location)
        try StoreInspector.assertSound(at: location, "after the second attempt")
        let remaining = rows.filter { $0.id != 1 }
        let listed = try await store.page(limit: 1_000).map(\.id)
        XCTAssertEqual(listed, expectedOrder(remaining))
        try await assertSearches(store, find: remaining, queries: ["alpha", "be", "zebra"])
    }

    func testTheMoveToVersionFiveDropsRowsThatReferToNoItem() async throws {
        _ = try buildVersionFour(VersionFourFixture.rows(count: 20))
        do {
            // Only a connection without foreign keys can write such rows.
            let db = try Database(path: location.database.path)
            try db.run("INSERT INTO representations (item_id, position, type, data) VALUES (999, 0, 'public.rtf', x'00')")
            try db.run("INSERT INTO files (item_id, position, path) VALUES (999, 0, '/tmp/stray')")
        }
        _ = try ClipStore(location: location)
        let db = try Database(path: location.database.path)
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM representations WHERE item_id = 999"), 0)
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM files WHERE item_id = 999"), 0)
        try StoreInspector.assertSound(at: location)
    }

    func testAnEmptyVersionFourHistoryMigrates() async throws {
        _ = try buildVersionFour([])
        let store = try ClipStore(location: location)
        let db = try Database(path: location.database.path)
        try StoreInspector.assertSound(at: location)
        XCTAssertEqual(try StoreInspector.schema(db), try freshSchema())
        let id = try await store.insert(Fixtures.textCapture("first after the move")).id
        let found = try await store.search("move").map(\.id)
        XCTAssertEqual(found, [id])
        XCTAssertEqual(try db.scalarInt("SELECT seq FROM items WHERE id = ?", [.int(id)]), 1)
    }

    // MARK: - Older versions

    func testEveryOlderVersionReachesVersionFive() async throws {
        let schema = try freshSchema()
        for version in 1...3 {
            let root = directory.appendingPathComponent("v\(version)", isDirectory: true)
            let location = StoreLocation(root: root)
            try FileManager.default.createDirectory(at: location.thumbs, withIntermediateDirectories: true)
            var rows = VersionFourFixture.rows(count: 200, seed: UInt64(version))
            let thumbnail = Fixtures.png(width: 3, height: 3)
            for index in rows.indices {
                // Before version 4, nothing recorded thumbnail sizes. ClipDeck counts the files on
                // disk.
                rows[index].thumbSize = 0
                if rows[index].kind != .text, index % 2 == 0 {
                    try thumbnail.write(to: location.thumbnailURL(for: rows[index].hash))
                    rows[index].thumbSize = Int64(thumbnail.count)
                }
                if version < 3 { rows[index].offersPlainText = true }
                if version < 2 { rows[index].offersTIFF = false }
            }
            let before: (items: [String], children: [String])
            do {
                let db = try VersionFourFixture.open(at: location, version: version)
                try db.transaction {
                    for row in rows { try VersionFourFixture.insert(row, into: db, version: version) }
                }
                before = (try StoreInspector.items(db, columns: []), try StoreInspector.children(db))
            }

            let store = try ClipStore(location: location)
            let db = try Database(path: location.database.path)
            XCTAssertEqual(try db.userVersion(), 5, "from \(version)")
            XCTAssertEqual(try StoreInspector.items(db, columns: []), before.items, "from \(version)")
            XCTAssertEqual(try StoreInspector.children(db), before.children, "from \(version)")
            XCTAssertEqual(try StoreInspector.schema(db), schema, "from \(version)")
            try StoreInspector.assertSound(at: location, "from \(version)")
            let flags = try db.query("SELECT offers_tiff, offers_plain_text, thumb_size FROM items ORDER BY id") {
                [$0.int64(0), $0.int64(1), $0.int64(2)]
            }
            XCTAssertEqual(flags, rows.map { [$0.offersTIFF ? 1 : 0, $0.offersPlainText ? 1 : 0, $0.thumbSize] }, "from \(version)")
            let used = try await store.storageUsage()
            XCTAssertEqual(used, rows.reduce(0) { $0 + ($1.kind == .file ? 0 : $1.byteSize) + $1.thumbSize }, "from \(version)")
            let listed = try await store.page(limit: 1_000).map(\.id)
            XCTAssertEqual(listed, expectedOrder(rows), "from \(version)")
            try await assertSearches(store, find: rows, queries: ["alpha", "co", "zebra", "tmp"])
        }
    }
}

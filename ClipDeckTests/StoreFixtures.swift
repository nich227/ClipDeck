import XCTest
@testable import ClipDeck

/// The generator has a seed, so a failing run can be repeated.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func chance(_ probability: Double) -> Bool {
        Double.random(in: 0..<1, using: &self) < probability
    }

    mutating func pick<T>(_ values: [T]) -> T {
        values[Int.random(in: 0..<values.count, using: &self)]
    }
}

/// These are the expected search index results, calculated without SQLite.
enum SearchModel {
    /// The index lowercases a text, removes its diacritics, and splits it at every character that
    /// is not a letter or digit.
    static func tokens(of text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .split { !($0.properties.isAlphabetic || $0.properties.numericType != nil) }
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// The result is true when every query word is a prefix of a word in the text.
    static func matches(_ text: String, query: String) -> Bool {
        let words = tokens(of: text)
        return tokens(of: query).allSatisfy { prefix in words.contains { $0.hasPrefix(prefix) } }
    }

    /// The row preview for text contains its first 300 characters when the text is longer than 300
    /// bytes, stopping at a NUL. Otherwise, it contains the whole text.
    static func preview(of text: String) -> String {
        guard text.utf8.count > 300 else { return text }
        let start = text.unicodeScalars.prefix(300).prefix { $0.value != 0 }
        return String(String.UnicodeScalarView(start))
    }
}

/// It reads a store's database through a second connection.
enum StoreInspector {
    private static func hex(_ column: String) -> String {
        "typeof(\(column)) || ':' || hex(CAST(\(column) AS BLOB))"
    }

    /// Each row appears on one line and includes every column a version 4 row has. Rows are in id
    /// order. Dates are compared bit for bit.
    static func items(_ db: Database, columns: [String] = ["offers_tiff", "offers_plain_text", "thumb_size"]) throws -> [String] {
        let extra = columns.isEmpty ? "" : ", " + columns.joined(separator: ", ")
        let sql = """
            SELECT id, \(hex("hash")), kind, created_at, last_used, \(hex("title")), \(hex("detail")), \(hex("search_text")),
                byte_size, \(hex("blob_type")), file_count\(extra)
            FROM items ORDER BY id
            """
        return try db.query(sql) { row in
            var fields = [
                String(row.int64(0)), row.string(1) ?? "", String(row.int64(2)), String(row.double(3).bitPattern),
                String(row.double(4).bitPattern), row.string(5) ?? "", row.string(6) ?? "", row.string(7) ?? "",
                String(row.int64(8)), row.string(9) ?? "", String(row.int64(10)),
            ]
            for offset in columns.indices { fields.append(String(row.int64(Int32(11 + offset)))) }
            return fields.joined(separator: "|")
        }
    }

    static func children(_ db: Database) throws -> [String] {
        let formats = try db.query(
            "SELECT item_id, position, type, hex(data) FROM representations ORDER BY item_id, position"
        ) { "r|\($0.int64(0))|\($0.int64(1))|\($0.string(2) ?? "")|\($0.string(3) ?? "")" }
        let files = try db.query(
            "SELECT item_id, position, path, \(hex("bookmark")) FROM files ORDER BY item_id, position"
        ) { "f|\($0.int64(0))|\($0.int64(1))|\($0.string(2) ?? "")|\($0.string(3) ?? "")" }
        return formats + files
    }

    /// Every table, index, and trigger includes its definition.
    static func schema(_ db: Database) throws -> [String] {
        try db.query(
            "SELECT type, name, tbl_name, coalesce(sql, '') FROM sqlite_master ORDER BY type, name"
        ) { "\($0.string(0) ?? "")|\($0.string(1) ?? "")|\($0.string(2) ?? "")|\($0.string(3) ?? "")" }
    }

    static func ids(_ db: Database, orderedBy order: String) throws -> [Int64] {
        try db.query("SELECT id FROM items ORDER BY \(order)") { $0.int64(0) }
    }

    /// Checks everything that a version 5 database must keep true, regardless of what was written
    /// to it. The check opens its own connection because a connection that read the search index
    /// before another connection changed it reports the index as malformed.
    static func assertSound(at location: StoreLocation, _ context: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
        let db = try Database(path: location.database.path)
        let integrity = try db.query("PRAGMA integrity_check") { $0.string(0) ?? "" }
        XCTAssertEqual(integrity, ["ok"], context, file: file, line: line)
        let broken = try db.query("PRAGMA foreign_key_check") { $0.string(0) ?? "" }
        XCTAssertEqual(broken, [], "rows that refer to no item. \(context)", file: file, line: line)
        for table in ["representations", "files"] {
            let parents = try db.query("PRAGMA foreign_key_list(\(table))") { "\($0.string(2) ?? "").\($0.string(4) ?? "")" }
            XCTAssertEqual(parents, ["items.id"], context, file: file, line: line)
        }
        XCTAssertEqual(
            try db.scalarInt("SELECT count(*) FROM items WHERE seq NOT IN (SELECT id FROM items_fts_docsize)"), 0,
            "a row is missing from the search index. \(context)", file: file, line: line
        )
        XCTAssertEqual(
            try db.scalarInt("SELECT count(*) FROM items_fts_docsize WHERE id NOT IN (SELECT seq FROM items)"), 0,
            "the search index holds an entry for no row. \(context)", file: file, line: line
        )
        XCTAssertNoThrow(
            try db.run("INSERT INTO items_fts (items_fts) VALUES ('integrity-check')"), context, file: file, line: line
        )
        XCTAssertEqual(
            try ids(db, orderedBy: "seq DESC"), try ids(db, orderedBy: "last_used DESC, id DESC"),
            "the index order is not the list order. \(context)", file: file, line: line
        )
        XCTAssertEqual(
            try db.scalarInt(ClipStore.totalBytesSQL),
            try db.scalarInt("SELECT coalesce(sum(\(ClipStore.storedBytesSQL)), 0) FROM items"),
            "the byte counter drifted. \(context)", file: file, line: line
        )
        XCTAssertEqual(
            try db.scalarInt("SELECT count(*) FROM items WHERE (preview IS NULL) <> (octet_length(search_text) <= 300)"), 0,
            "a row has the wrong kind of preview. \(context)", file: file, line: line
        )
        XCTAssertEqual(
            try db.scalarInt("SELECT count(*) FROM items WHERE preview IS NOT NULL AND preview <> substr(search_text, 1, 300)"), 0,
            "a preview is not the start of its text. \(context)", file: file, line: line
        )
    }
}

/// This builds a schema version 4 database as an earlier build left it.
enum VersionFourFixture {
    struct Row {
        var id: Int64
        var hash: String
        var kind: ClipKind
        var createdAt: Double
        var lastUsed: Double
        var title: String
        var detail: String?
        /// The text's UTF-8 bytes may be invalid.
        var text: Data
        var byteSize: Int64
        var blobType: String?
        var offersTIFF = false
        var offersPlainText = true
        var thumbSize: Int64 = 0
        var representations: [PasteboardRepresentation] = []
        var files: [FileReference] = []

        var decodedText: String { String(decoding: text, as: UTF8.self) }
    }

    static func open(at location: StoreLocation, version: Int = 4) throws -> Database {
        let db = try Database(path: location.database.path)
        try ClipStore.configure(db)
        try ClipStore.migrate(db, upTo: version)
        return db
    }

    /// Writes the row with the columns defined in that schema version.
    static func insert(_ row: Row, into db: Database, version: Int = 4) throws {
        var columns = "id, hash, kind, created_at, last_used, title, detail, search_text, byte_size, blob_type, file_count"
        var slots = "?, ?, ?, ?, ?, ?, ?, CAST(? AS TEXT), ?, ?, ?"
        var values: [SQLValue] = [
            .int(row.id), .text(row.hash), .int(Int64(row.kind.rawValue)), .double(row.createdAt), .double(row.lastUsed),
            .text(row.title), row.detail.map(SQLValue.text) ?? .null, .blob(row.text), .int(row.byteSize),
            row.blobType.map(SQLValue.text) ?? .null, .int(Int64(row.files.count)),
        ]
        if version >= 2 {
            columns += ", offers_tiff"
            slots += ", ?"
            values.append(.int(row.offersTIFF ? 1 : 0))
        }
        if version >= 3 {
            columns += ", offers_plain_text"
            slots += ", ?"
            values.append(.int(row.offersPlainText ? 1 : 0))
        }
        if version >= 4 {
            columns += ", thumb_size"
            slots += ", ?"
            values.append(.int(row.thumbSize))
        }
        try db.run("INSERT INTO items (\(columns)) VALUES (\(slots))", values)
        for (position, representation) in row.representations.enumerated() {
            try db.run(
                "INSERT INTO representations (item_id, position, type, data) VALUES (?, ?, ?, ?)",
                [.int(row.id), .int(Int64(position)), .text(representation.type), .blob(representation.data)]
            )
        }
        for (position, file) in row.files.enumerated() {
            try db.run(
                "INSERT INTO files (item_id, position, path, bookmark) VALUES (?, ?, ?, ?)",
                [.int(row.id), .int(Int64(position)), .text(file.path), file.bookmark.map(SQLValue.blob) ?? .null]
            )
        }
    }

    static let vocabulary = [
        "alpha", "alpine", "beta", "better", "gamma", "delta", "config", "connect", "copy", "zebra", "caf\u{E9}", "na\u{EF}ve",
        "42", "4242", "\u{65E5}\u{672C}\u{8A9E}", "x",
    ]

    /// Rows of every kind and shape include no detail, empty and long texts, a NUL, invalid bytes,
    /// shared dates, flags, thumbnail sizes, formats, and file references.
    static func rows(count: Int, seed: UInt64 = 4) -> [Row] {
        var random = SeededGenerator(seed: seed)
        func text(_ id: Int64, _ string: String, title: String? = nil) -> Row {
            Row(
                id: id, hash: "hash-\(id)", kind: .text, createdAt: Double(id), lastUsed: Double(id),
                title: title ?? String(string.prefix(40)), detail: nil, text: Data(string.utf8), byteSize: Int64(string.utf8.count),
                blobType: nil
            )
        }
        var rows: [Row] = []
        var plain = text(1, "alpha note")
        plain.offersPlainText = false
        plain.representations = [PasteboardRepresentation(type: PasteboardTypes.rtf, data: Data("{\\rtf1 alpha}".utf8))]
        rows.append(plain)
        rows.append(text(2, ""))
        rows.append(text(3, String(repeating: "caf\u{E9} \u{1F4CE} gamma ", count: 400)))
        rows.append(text(4, "ab\u{0}" + String(repeating: "zebra ", count: 3_000)))
        rows.append(text(5, String(repeating: "beta ", count: 60)))
        rows.append(text(6, String(repeating: "beta ", count: 60) + "x"))
        rows.append(text(7, String(repeating: "\u{E9}", count: 300)))
        var invalid = text(8, "", title: "invalid")
        invalid.text = Data("qq".utf8) + Data([0xFF, 0xFE, 0xC3]) + Data("qq zebra".utf8)
        rows.append(invalid)
        rows.append(Row(
            id: 9, hash: "hash-9", kind: .image, createdAt: 9, lastUsed: 9, title: "Image 4\u{D7}3", detail: nil,
            text: Data("Image 4\u{D7}3".utf8), byteSize: 2_000, blobType: PasteboardTypes.png, offersTIFF: true,
            offersPlainText: false, thumbSize: 50,
            representations: [PasteboardRepresentation(type: PasteboardTypes.html, data: Data())]
        ))
        rows.append(Row(
            id: 10, hash: "hash-10", kind: .file, createdAt: 10, lastUsed: 10, title: "clip.mov and 1 more",
            detail: "/tmp/clip.mov", text: Data("/tmp/clip.mov\n/tmp/copy two.txt".utf8), byteSize: 30_000, blobType: nil,
            offersPlainText: false, thumbSize: 7,
            files: [FileReference(path: "/tmp/clip.mov", bookmark: Data([1, 0, 2])), FileReference(path: "/tmp/copy two.txt", bookmark: nil)]
        ))
        while rows.count < count {
            let id = Int64(rows.count + 1)
            let words = (0..<Int.random(in: 1...6, using: &random)).map { _ in random.pick(vocabulary) }
            // There are few distinct dates, so many rows share the same date.
            let lastUsed = Double(Int.random(in: 0..<max(count / 3, 2), using: &random)) + (random.chance(0.2) ? 0.5 : 0)
            let roll = Double.random(in: 0..<1, using: &random)
            var row: Row
            if roll < 0.7 {
                row = text(id, words.joined(separator: " ") + " u\(id)")
                row.offersPlainText = random.chance(0.8)
                if random.chance(0.3) {
                    row.representations = (0..<Int.random(in: 1...2, using: &random)).map {
                        PasteboardRepresentation(type: $0 == 0 ? PasteboardTypes.rtf : PasteboardTypes.html, data: Data("{\(id)}".utf8))
                    }
                }
            } else if roll < 0.85 {
                let title = "Image \(id)\u{D7}3"
                row = Row(
                    id: id, hash: "hash-\(id)", kind: .image, createdAt: 0, lastUsed: 0, title: title, detail: nil,
                    text: Data(title.utf8), byteSize: Int64.random(in: 1...9_000, using: &random), blobType: PasteboardTypes.png,
                    offersTIFF: random.chance(0.5), offersPlainText: false,
                    thumbSize: random.chance(0.6) ? Int64.random(in: 1...900, using: &random) : 0
                )
            } else {
                let paths = words.prefix(3).enumerated().map { "/tmp/\($1) \(id)-\($0).txt" }
                row = Row(
                    id: id, hash: "hash-\(id)", kind: .file, createdAt: 0, lastUsed: 0, title: (paths[0] as NSString).lastPathComponent,
                    detail: paths[0], text: Data(paths.joined(separator: "\n").utf8), byteSize: Int64.random(in: 0...9_000_000, using: &random),
                    blobType: nil, offersPlainText: false, thumbSize: random.chance(0.5) ? Int64.random(in: 1...900, using: &random) : 0,
                    files: paths.map { FileReference(path: $0, bookmark: random.chance(0.8) ? Data("bookmark:\($0)".utf8) : nil) }
                )
            }
            row.createdAt = lastUsed - Double(Int.random(in: 0...5, using: &random))
            row.lastUsed = lastUsed
            rows.append(row)
        }
        return rows
    }
}

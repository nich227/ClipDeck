import Foundation

/// The store keeps its database and files in these locations.
struct StoreLocation: Sendable {
    let root: URL

    var database: URL { root.appendingPathComponent(Constants.databaseFileName) }
    var blobs: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    var thumbs: URL { root.appendingPathComponent("thumbs", isDirectory: true) }

    func blobURL(for hash: String) -> URL { blobs.appendingPathComponent(hash) }
    func thumbnailURL(for hash: String) -> URL { thumbs.appendingPathComponent("\(hash).png") }

    static func applicationSupport() throws -> StoreLocation {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return StoreLocation(root: base.appendingPathComponent(Constants.supportDirectoryName, isDirectory: true))
    }
}

enum StoreError: Error, Equatable {
    case newerSchema(Int)
}

enum InsertOutcome: Equatable, Sendable {
    case inserted(Int64)
    case bumped(Int64)

    var id: Int64 {
        switch self {
        case .inserted(let id), .bumped(let id): return id
        }
    }
}

/// The clipboard history uses SQLite for rows and search, and content-addressed files for blobs and
/// thumbnails. One serial queue owns the connection, and every call runs on that queue.
final class ClipStore: @unchecked Sendable {
    static let schemaVersion = 4

    let location: StoreLocation
    private let queue = DispatchQueue(label: "com.kevster.clipdeck.store", qos: .userInitiated)
    private let db: Database
    /// This value sets the maximum number of bytes in the history, or nil for no limit. Code
    /// accesses it only on the store queue.
    private var budgetBytes: Int64?

    init(location: StoreLocation) throws {
        self.location = location
        for directory in [location.root, location.blobs, location.thumbs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let db = try Database(path: location.database.path)
        try queue.sync {
            try Self.configure(db)
            let before = try db.userVersion()
            try Self.migrate(db)
            if before < 4 {
                try Self.recordThumbnailSizes(db, location: location)
            }
        }
        self.db = db
    }

    // MARK: - Writes

    /// This operation inserts a capture or moves an existing item with the same hash to the top. A
    /// moved item uses the new copy's formats, so Return pastes what was copied most recently. When
    /// the history exceeds its limit, the operation removes the oldest items before returning.
    func insert(_ capture: Capture, at date: Date = Date()) async throws -> InsertOutcome {
        try await perform { db in
            if let blob = capture.blob {
                try self.writeFileIfMissing(blob.data, to: self.location.blobURL(for: capture.hash))
            }
            let outcome: InsertOutcome = try db.transaction {
                try db.run(Self.bumpSQL, [.double(date.timeIntervalSince1970), .text(capture.hash)])
                if db.changes > 0, let id = try db.scalarInt("SELECT id FROM items WHERE hash = ?", [.text(capture.hash)]) {
                    try db.run(
                        "UPDATE items SET byte_size = ?, offers_tiff = ?, offers_plain_text = ? WHERE id = ?",
                        [
                            .int(capture.byteSize),
                            .int(capture.offersTIFF ? 1 : 0),
                            .int(capture.offersPlainText ? 1 : 0),
                            .int(id),
                        ]
                    )
                    try db.run("DELETE FROM representations WHERE item_id = ?", [.int(id)])
                    try db.run("DELETE FROM files WHERE item_id = ?", [.int(id)])
                    try Self.insertChildren(of: capture, id: id, db: db)
                    return .bumped(id)
                }
                try db.run(
                    """
                    INSERT INTO items (hash, kind, created_at, last_used, title, detail, search_text, byte_size, blob_type, file_count, offers_tiff, offers_plain_text)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(capture.hash),
                        .int(Int64(capture.kind.rawValue)),
                        .double(date.timeIntervalSince1970),
                        .double(date.timeIntervalSince1970),
                        .text(capture.title),
                        capture.detail.map(SQLValue.text) ?? .null,
                        .text(capture.searchText),
                        .int(capture.byteSize),
                        capture.blob.map { SQLValue.text($0.type) } ?? .null,
                        .int(Int64(capture.files.count)),
                        .int(capture.offersTIFF ? 1 : 0),
                        .int(capture.offersPlainText ? 1 : 0),
                    ]
                )
                let id = db.lastInsertRowID
                try Self.insertChildren(of: capture, id: id, db: db)
                return .inserted(id)
            }
            try self.evictWhileOverBudget(db)
            return outcome
        }
    }

    private static func insertChildren(of capture: Capture, id: Int64, db: Database) throws {
        for (position, representation) in capture.representations.enumerated() {
            try db.run(
                "INSERT INTO representations (item_id, position, type, data) VALUES (?, ?, ?, ?)",
                [.int(id), .int(Int64(position)), .text(representation.type), .blob(representation.data)]
            )
        }
        for (position, file) in capture.files.enumerated() {
            try db.run(
                "INSERT INTO files (item_id, position, path, bookmark) VALUES (?, ?, ?, ?)",
                [.int(id), .int(Int64(position)), .text(file.path), file.bookmark.map(SQLValue.blob) ?? .null]
            )
        }
    }

    /// Moves an item to the top when the user copies it again from the panel.
    func touch(id: Int64, at date: Date = Date()) async throws {
        try await perform { db in
            try db.run("UPDATE items SET last_used = ? WHERE id = ?", [.double(date.timeIntervalSince1970), .int(id)])
        }
    }

    /// The method saves a thumbnail unless every row with this hash was deleted during thumbnail
    /// creation. It returns true when it saves the thumbnail.
    @discardableResult
    func saveThumbnail(_ png: Data, for hash: String) async throws -> Bool {
        try await perform { db in
            guard let id = try db.scalarInt("SELECT id FROM items WHERE hash = ?", [.text(hash)]) else {
                return false
            }
            try png.write(to: self.location.thumbnailURL(for: hash), options: .atomic)
            try db.run("UPDATE items SET thumb_size = ? WHERE id = ?", [.int(Int64(png.count)), .int(id)])
            try self.evictWhileOverBudget(db)
            return true
        }
    }

    // MARK: - Storage limit

    /// The operation applies a limit, or no limit when the value is nil, and removes the oldest
    /// items until the history fits. Each batch uses its own queue hop, so reads interleave during
    /// a long eviction. It returns the number of items removed.
    @discardableResult
    func setStorageBudget(_ bytes: Int64?) async throws -> Int {
        try await perform { _ in self.budgetBytes = bytes }
        var removed = 0
        while true {
            let batch = try await perform { db in try self.evictBatch(db) }
            removed += batch.count
            if batch.count < Constants.Storage.evictionBatch { return removed }
        }
    }

    /// The history tracks the content size in bytes for text and its formatting, image data, and
    /// thumbnails. Reading the history requires one row. Triggers keep the counter current.
    func storageUsage() async throws -> Int64 {
        try await perform { db in try Self.totalBytes(db) }
    }

    private func evictWhileOverBudget(_ db: Database) throws {
        while try evictBatch(db).count == Constants.Storage.evictionBatch {}
    }

    /// It removes up to one batch of the oldest items while the history exceeds its limit. It reads
    /// the oldest items first using the `items_recent` index, so each row costs O(log n). It never
    /// removes the newest row. It returns the hashes of the removed rows.
    private func evictBatch(_ db: Database) throws -> [String] {
        guard let budget = budgetBytes else { return [] }
        let total = try Self.totalBytes(db)
        guard total > budget, let newest = try db.scalarInt(Self.newestSQL) else { return [] }
        let candidates = try db.query(Self.oldestSQL, [.int(Int64(Constants.Storage.evictionBatch))]) {
            EvictionCandidate(id: $0.int64(0), hash: $0.string(1) ?? "", bytes: $0.int64(2))
        }
        let plan = EvictionPlan.select(from: candidates, excess: total - budget, keeping: newest)
        guard !plan.isEmpty else { return [] }
        try db.transaction {
            let delete = try db.prepare("DELETE FROM items WHERE id = ?")
            for candidate in plan {
                delete.reset()
                try delete.bind([.int(candidate.id)])
                while try delete.step() {}
            }
        }
        let hashes = plan.map(\.hash)
        try removeUnreferencedFiles(named: hashes, db: db)
        let freed = plan.reduce(0) { $0 + $1.bytes }
        Log.store.info("Removed \(plan.count) items (\(freed) bytes) to stay under the storage limit")
        return hashes
    }

    private static func totalBytes(_ db: Database) throws -> Int64 {
        try db.scalarInt(totalBytesSQL) ?? 0
    }

    // MARK: - Sessions

    /// This marks the start of a session. It returns false if the previous session did not call
    /// `markCleanShutdown`. In that case, files may be orphaned and the byte counter may be
    /// inaccurate.
    func beginSession() async throws -> Bool {
        try await perform { db in
            let clean = try db.scalarInt("SELECT clean_shutdown FROM stats WHERE id = 1") == 1
            try db.run("UPDATE stats SET clean_shutdown = 0 WHERE id = 1")
            return clean
        }
    }

    /// This records an orderly shutdown and waits for the queue because the app is terminating. A
    /// continuation would receive nothing.
    func markCleanShutdown() {
        queue.sync {
            do {
                try db.run("UPDATE stats SET clean_shutdown = 1 WHERE id = 1")
            } catch {
                Log.store.error("Could not record the clean shutdown: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Reads

    /// The result contains one page of history, with the newest entries first. Pass the last row
    /// shown to get the next page.
    func page(after cursor: PageCursor? = nil, limit: Int = Constants.List.pageSize) async throws -> [ClipItem] {
        try await perform { db in
            let volumes = LocalVolumes.current()
            let blobs = self.location
            if let cursor {
                return try db.query(
                    Self.pageAfterSQL,
                    [.double(cursor.lastUsed.timeIntervalSince1970), .int(cursor.id), .int(Int64(limit))]
                ) { Self.item(from: $0, volumes: volumes, location: blobs) }
            }
            return try db.query(Self.pageSQL, [.int(Int64(limit))]) { Self.item(from: $0, volumes: volumes, location: blobs) }
        }
    }

    /// The full-text search treats every word as a prefix and returns the newest matches first.
    /// Pass the last row shown to get the next page. Each page sorts only the matches older than
    /// that row.
    func search(_ text: String, after cursor: PageCursor? = nil, limit: Int = Constants.List.pageSize) async throws -> [ClipItem] {
        guard let match = Self.ftsQuery(from: text) else { return [] }
        return try await perform { db in
            let volumes = LocalVolumes.current()
            let lastUsed = cursor?.lastUsed.timeIntervalSince1970 ?? .infinity
            let id = cursor?.id ?? .max
            return try db.query(
                Self.searchSQL,
                [.text(match), .double(lastUsed), .int(id), .int(Int64(limit))]
            ) { Self.item(from: $0, volumes: volumes, location: self.location) }
        }
    }

    func count() async throws -> Int {
        try await perform { db in Int(try db.scalarInt("SELECT count(*) FROM items") ?? 0) }
    }

    func payload(for id: Int64) async throws -> ClipPayload? {
        try await perform { db in
            let rows = try db.query(
                "SELECT kind, search_text, hash, blob_type, offers_tiff, offers_plain_text FROM items WHERE id = ?", [.int(id)]
            ) { row in
                (
                    ClipKind(rawValue: Int(row.int64(0))) ?? .text, row.string(1) ?? "", row.string(2) ?? "",
                    row.string(3), row.int64(4) != 0, row.int64(5) != 0
                )
            }
            guard let (kind, searchText, hash, blobType, offersTIFF, offersPlainText) = rows.first else { return nil }
            let representations = try db.query(
                "SELECT type, data FROM representations WHERE item_id = ? ORDER BY position", [.int(id)]
            ) { PasteboardRepresentation(type: $0.string(0) ?? "", data: $0.data(1) ?? Data()) }
            let files = try db.query(
                "SELECT path, bookmark FROM files WHERE item_id = ? ORDER BY position", [.int(id)]
            ) { FileReference(path: $0.string(0) ?? "", bookmark: $0.data(1)) }
            var blob: PasteboardRepresentation?
            if let blobType {
                guard let data = try? Data(contentsOf: self.location.blobURL(for: hash)) else {
                    Log.store.error("Blob for item \(id) is missing")
                    return nil
                }
                blob = PasteboardRepresentation(type: blobType, data: data)
            }
            var restored = representations
            if offersTIFF, blobType != PasteboardTypes.tiff, let data = blob?.data, let tiff = ImageProcessing.tiffData(from: data) {
                restored.insert(PasteboardRepresentation(type: PasteboardTypes.tiff, data: tiff), at: 0)
            }
            return ClipPayload(
                kind: kind,
                plainText: kind == .text && offersPlainText ? searchText : nil,
                representations: restored,
                files: files,
                blob: blob
            )
        }
    }

    /// The preview pane shows the start of an item's text and includes more text than the row
    /// preview.
    func textPreview(for id: Int64, maxCharacters: Int = Constants.List.detailPreviewCharacters) async throws -> String {
        try await perform { db in
            try db.query("SELECT substr(search_text, 1, ?) FROM items WHERE id = ?", [.int(Int64(maxCharacters)), .int(id)]) {
                $0.string(0) ?? ""
            }.first ?? ""
        }
    }

    func schemaVersionOnDisk() async throws -> Int {
        try await perform { db in try db.userVersion() }
    }

    // MARK: - Clearing

    func count(matching request: ClearRequest) async throws -> Int {
        guard let (clause, values) = Self.predicate(for: request) else { return 0 }
        return try await perform { db in
            Int(try db.scalarInt("SELECT count(*) FROM items WHERE \(clause)", values) ?? 0)
        }
    }

    /// It deletes the matching rows, then deletes any blob or thumbnail that no remaining row
    /// references.
    @discardableResult
    func clear(_ request: ClearRequest) async throws -> Int {
        guard let (clause, values) = Self.predicate(for: request) else { return 0 }
        return try await perform { db in
            let removed: [String] = try db.transaction {
                let hashes = try db.query("SELECT hash FROM items WHERE \(clause)", values) { $0.string(0) ?? "" }
                try db.run("DELETE FROM items WHERE \(clause)", values)
                return hashes
            }
            try self.removeUnreferencedFiles(named: removed, db: db)
            Log.store.info("Cleared \(removed.count) items")
            return removed.count
        }
    }

    /// This method repairs data a crash can leave behind. The data includes blob and thumbnail
    /// files with no row references, a thumbnail written before its size was recorded, and a byte
    /// counter that drifted. This repair is only needed after a session ends without calling
    /// `markCleanShutdown`.
    ///
    /// Listing the directory takes O(files) time and runs outside the store queue. The method runs
    /// the checks on the queue in chunks of `Constants.Storage.sweepBatch`, so reads interleave
    /// with the sweep. It returns the number of files removed.
    @discardableResult
    func collectGarbage() async throws -> Int {
        let location = self.location
        let listing: [(URL, [String])] = await Task.detached(priority: .utility) {
            [location.blobs, location.thumbs].map { directory in
                (directory, (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            }
        }.value
        var removed = 0
        for (directory, names) in listing {
            let isThumbs = directory == location.thumbs
            for start in stride(from: 0, to: names.count, by: Constants.Storage.sweepBatch) {
                let chunk = Array(names[start..<min(start + Constants.Storage.sweepBatch, names.count)])
                removed += try await perform { db in
                    try self.sweep(chunk, in: directory, recordingThumbnailSizes: isThumbs, db: db)
                }
            }
        }
        try await perform { db in
            try db.run("UPDATE stats SET total_bytes = (SELECT coalesce(sum(\(Self.storedBytesSQL)), 0) FROM items) WHERE id = 1")
        }
        return removed
    }

    private func sweep(_ names: [String], in directory: URL, recordingThumbnailSizes: Bool, db: Database) throws -> Int {
        let lookup = try db.prepare("SELECT id, thumb_size FROM items WHERE hash = ?")
        let record = try db.prepare("UPDATE items SET thumb_size = ? WHERE id = ?")
        var removed = 0
        try db.transaction {
            for name in names {
                let hash = (name as NSString).deletingPathExtension
                let url = directory.appendingPathComponent(name)
                lookup.reset()
                try lookup.bind([.text(hash)])
                guard try lookup.step() else {
                    try? FileManager.default.removeItem(at: url)
                    removed += 1
                    continue
                }
                if recordingThumbnailSizes, lookup.int64(1) == 0 {
                    record.reset()
                    try record.bind([.int(PasteboardClassifier.size(ofFileAt: url.path)), .int(lookup.int64(0))])
                    while try record.step() {}
                }
            }
        }
        return removed
    }

    // MARK: - Query helpers

    /// This builds an FTS5 query that treats every word as a prefix. It quotes each word, so the
    /// query searches for user-entered FTS operators as text.
    static func ftsQuery(from text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " ")
    }

    private static func predicate(for request: ClearRequest) -> (String, [SQLValue])? {
        guard !request.kinds.isEmpty else { return nil }
        let kinds = request.kinds.map { String($0.rawValue) }.sorted().joined(separator: ", ")
        guard let cutoff = request.cutoff else { return ("kind IN (\(kinds))", []) }
        return ("kind IN (\(kinds)) AND last_used >= ?", [.double(cutoff.timeIntervalSince1970)])
    }

    private static let itemColumns = """
        items.id, items.hash, items.kind, items.created_at, items.last_used, items.title, items.detail, \
        substr(items.search_text, 1, \(Constants.List.rowPreviewCharacters)), items.byte_size, items.blob_type, items.file_count
        """

    static let pageSQL = "SELECT \(itemColumns) FROM items ORDER BY last_used DESC, id DESC LIMIT ?"
    static let pageAfterSQL = """
        SELECT \(itemColumns) FROM items WHERE (last_used, id) < (?, ?) ORDER BY last_used DESC, id DESC LIMIT ?
        """
    static let bumpSQL = "UPDATE items SET last_used = ? WHERE hash = ?"
    static let searchSQL = """
        SELECT \(itemColumns) FROM items_fts JOIN items ON items.id = items_fts.rowid
        WHERE items_fts MATCH ? AND (items.last_used, items.id) < (?, ?)
        ORDER BY items.last_used DESC, items.id DESC LIMIT ?
        """
    static let totalBytesSQL = "SELECT total_bytes FROM stats WHERE id = 1"
    static let newestSQL = "SELECT id FROM items ORDER BY last_used DESC, id DESC LIMIT 1"
    /// This is how many bytes a row holds on disk. A file item stores a reference and a thumbnail,
    /// but it does not store the file.
    static let storedBytesSQL = "(CASE WHEN kind = \(ClipKind.file.rawValue) THEN 0 ELSE byte_size END) + thumb_size"
    static let oldestSQL = "SELECT id, hash, \(storedBytesSQL) FROM items ORDER BY last_used ASC, id ASC LIMIT ?"

    private static func item(from row: Statement, volumes: LocalVolumes, location: StoreLocation) -> ClipItem {
        let kind = ClipKind(rawValue: Int(row.int64(2))) ?? .text
        let hash = row.string(1) ?? ""
        let detail = row.string(6)
        let isMissing: Bool
        switch kind {
        case .file:
            isMissing = detail.map(volumes.isMissing(atPath:)) ?? true
        case .image:
            isMissing = !FileManager.default.fileExists(atPath: location.blobURL(for: hash).path)
        case .text:
            isMissing = false
        }
        return ClipItem(
            id: row.int64(0),
            hash: hash,
            kind: kind,
            createdAt: Date(timeIntervalSince1970: row.double(3)),
            lastUsed: Date(timeIntervalSince1970: row.double(4)),
            title: row.string(5) ?? "",
            detail: detail,
            preview: row.string(7) ?? "",
            byteSize: row.int64(8),
            blobType: row.string(9),
            fileCount: Int(row.int64(10)),
            isMissing: isMissing
        )
    }

    // MARK: - Files

    private func writeFileIfMissing(_ data: Data, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try data.write(to: url, options: .atomic)
    }

    private func removeUnreferencedFiles(named hashes: [String], db: Database) throws {
        let check = try db.prepare("SELECT 1 FROM items WHERE hash = ? LIMIT 1")
        for hash in hashes {
            check.reset()
            try check.bind([.text(hash)])
            if try check.step() { continue }
            try? FileManager.default.removeItem(at: location.blobURL(for: hash))
            try? FileManager.default.removeItem(at: location.thumbnailURL(for: hash))
        }
    }

    /// This records the size of every thumbnail made before thumbnail counting began. It runs once
    /// when a database older than version 4 opens.
    private static func recordThumbnailSizes(_ db: Database, location: StoreLocation) throws {
        let rows = try db.query(
            "SELECT id, hash FROM items WHERE kind != ?", [.int(Int64(ClipKind.text.rawValue))]
        ) { ($0.int64(0), $0.string(1) ?? "") }
        try db.transaction {
            let record = try db.prepare("UPDATE items SET thumb_size = ? WHERE id = ?")
            for (id, hash) in rows {
                let size = PasteboardClassifier.size(ofFileAt: location.thumbnailURL(for: hash).path)
                guard size > 0 else { continue }
                record.reset()
                try record.bind([.int(size), .int(id)])
                while try record.step() {}
            }
        }
    }

    // MARK: - Queue

    private func perform<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body(self.db) })
            }
        }
    }

    // MARK: - Schema

    static func configure(_ db: Database) throws {
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute("PRAGMA temp_store = MEMORY")
    }

    /// The schema advances one version at a time. Each step runs in its own transaction. `target`
    /// is below `schemaVersion` only in tests that build an older database.
    static func migrate(_ db: Database, upTo target: Int = schemaVersion) throws {
        let current = try db.userVersion()
        guard current <= schemaVersion else { throw StoreError.newerSchema(current) }
        guard current < target else { return }
        for version in current..<target {
            try db.transaction {
                try migrate(db, from: version)
                try db.setUserVersion(version + 1)
            }
            Log.store.info("Migrated schema to version \(version + 1)")
        }
    }

    private static func migrate(_ db: Database, from version: Int) throws {
        switch version {
        case 0:
            try db.execute("""
                CREATE TABLE items (
                    id INTEGER PRIMARY KEY,
                    hash TEXT NOT NULL UNIQUE,
                    kind INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    last_used REAL NOT NULL,
                    title TEXT NOT NULL,
                    detail TEXT,
                    search_text TEXT NOT NULL,
                    byte_size INTEGER NOT NULL,
                    blob_type TEXT,
                    file_count INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX items_recent ON items (last_used DESC, id DESC);
                CREATE INDEX items_kind_recent ON items (kind, last_used);
                CREATE TABLE representations (
                    item_id INTEGER NOT NULL REFERENCES items (id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    type TEXT NOT NULL,
                    data BLOB NOT NULL,
                    PRIMARY KEY (item_id, position)
                );
                CREATE TABLE files (
                    item_id INTEGER NOT NULL REFERENCES items (id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    path TEXT NOT NULL,
                    bookmark BLOB,
                    PRIMARY KEY (item_id, position)
                );
                CREATE VIRTUAL TABLE items_fts USING fts5 (
                    search_text, content = 'items', content_rowid = 'id', tokenize = 'unicode61 remove_diacritics 2'
                );
                CREATE TRIGGER items_fts_insert AFTER INSERT ON items BEGIN
                    INSERT INTO items_fts (rowid, search_text) VALUES (new.id, new.search_text);
                END;
                CREATE TRIGGER items_fts_delete AFTER DELETE ON items BEGIN
                    INSERT INTO items_fts (items_fts, rowid, search_text) VALUES ('delete', old.id, old.search_text);
                END;
                CREATE TRIGGER items_fts_update AFTER UPDATE OF search_text ON items BEGIN
                    INSERT INTO items_fts (items_fts, rowid, search_text) VALUES ('delete', old.id, old.search_text);
                    INSERT INTO items_fts (rowid, search_text) VALUES (new.id, new.search_text);
                END;
                """)
        case 1:
            try db.execute("ALTER TABLE items ADD COLUMN offers_tiff INTEGER NOT NULL DEFAULT 0")
        case 2:
            // Earlier versions always included plain text when restoring a text row to the
            // pasteboard.
            try db.execute("ALTER TABLE items ADD COLUMN offers_plain_text INTEGER NOT NULL DEFAULT 1")
        case 3:
            try db.execute("""
                ALTER TABLE items ADD COLUMN thumb_size INTEGER NOT NULL DEFAULT 0;
                CREATE TABLE stats (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    total_bytes INTEGER NOT NULL,
                    clean_shutdown INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO stats (id, total_bytes, clean_shutdown)
                VALUES (1, (SELECT coalesce(sum(CASE WHEN kind = 2 THEN 0 ELSE byte_size END), 0) FROM items), 0);
                CREATE TRIGGER items_stats_insert AFTER INSERT ON items BEGIN
                    UPDATE stats SET total_bytes = total_bytes
                        + (CASE WHEN new.kind = 2 THEN 0 ELSE new.byte_size END) + new.thumb_size
                    WHERE id = 1;
                END;
                CREATE TRIGGER items_stats_delete AFTER DELETE ON items BEGIN
                    UPDATE stats SET total_bytes = total_bytes
                        - (CASE WHEN old.kind = 2 THEN 0 ELSE old.byte_size END) - old.thumb_size
                    WHERE id = 1;
                END;
                CREATE TRIGGER items_stats_update AFTER UPDATE OF byte_size, thumb_size ON items BEGIN
                    UPDATE stats SET total_bytes = total_bytes
                        + (CASE WHEN new.kind = 2 THEN 0 ELSE new.byte_size END) + new.thumb_size
                        - (CASE WHEN old.kind = 2 THEN 0 ELSE old.byte_size END) - old.thumb_size
                    WHERE id = 1;
                END;
                """)
        default:
            break
        }
    }
}

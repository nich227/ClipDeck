import Darwin
import Foundation

/// The store keeps its database and files in these locations.
struct StoreLocation: Sendable {
    let root: URL

    var database: URL { root.appendingPathComponent(Constants.databaseFileName, isDirectory: false) }
    var blobs: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    var thumbs: URL { root.appendingPathComponent("thumbs", isDirectory: true) }
    /// Files being written wait here until the store queue moves them into place.
    var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }

    func blobURL(for hash: String) -> URL { blobs.appendingPathComponent(hash, isDirectory: false) }
    func thumbnailURL(for hash: String) -> URL { thumbs.appendingPathComponent("\(hash).png", isDirectory: false) }

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

extension StoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .newerSchema:
            return "This history was saved by a newer version of ClipDeck."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .newerSchema:
            return "Update ClipDeck to open it."
        }
    }
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
/// thumbnails. One serial queue owns the connection, and every database call runs on that queue. A
/// second queue reads and writes file bytes.
final class ClipStore: @unchecked Sendable {
    static let schemaVersion = 5

    let location: StoreLocation
    private let queue = DispatchQueue(label: "com.kevster.clipdeck.store", qos: .userInitiated)
    /// File bytes are written and read here, so a large image never blocks the store queue.
    private let fileQueue = DispatchQueue(label: "com.kevster.clipdeck.store.files", qos: .userInitiated, attributes: .concurrent)
    private let db: Database
    private let blobPrefix: String
    private let thumbPrefix: String
    private let stagingPrefix: String
    /// This value sets the maximum number of bytes in the history, or nil for no limit. The code
    /// accesses it only on the store queue.
    private var budgetBytes: Int64?

    init(location: StoreLocation) throws {
        self.location = location
        for directory in [location.root, location.blobs, location.thumbs, location.staging] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        blobPrefix = location.blobs.path + "/"
        thumbPrefix = location.thumbs.path + "/"
        stagingPrefix = location.staging.path + "/"
        // A crash or a quit interrupted the write that left this file here.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: location.staging.path)) ?? [] {
            unlink(stagingPrefix + name)
        }
        let db = try Database(path: location.database.path)
        try queue.sync {
            try Self.configure(db)
            let before = try db.userVersion()
            try Self.migrate(db)
            if before < 4 {
                try Self.recordThumbnailSizes(db, location: location)
            }
            if before < Self.schemaVersion {
                // A step that rebuilds the history leaves a log file as large as the history.
                try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            }
        }
        self.db = db
    }

    // MARK: - Writes

    /// This operation inserts a capture or moves an existing item with the same hash to the top. A
    /// moved item takes the new copy's formats, so Return copies what was copied most recently.
    /// When the history exceeds its limit, the operation removes the oldest items before returning.
    func insert(_ capture: Capture, at date: Date = Date()) async throws -> InsertOutcome {
        let staged = try await stageBlob(of: capture)
        return try await perform { db in
            do {
                try self.adoptBlob(of: capture, stagedAt: staged)
                let outcome = try db.transaction { try Self.store(capture, at: date, db: db) }
                try self.evictWhileOverBudget(db)
                return outcome
            } catch {
                if capture.blob != nil {
                    // The blob stays when the lookup itself fails. A later sweep removes a stray
                    // file, but a lost file is gone.
                    let named = (try? db.first(Self.idForHashSQL, [.text(capture.hash)]) { _ in true } != nil) ?? true
                    if !named { unlink(self.blobPrefix + capture.hash) }
                }
                throw error
            }
        }
    }

    private static func store(_ capture: Capture, at date: Date, db: Database) throws -> InsertOutcome {
        let seconds = try copyTime(for: date, db: db)
        let offersTIFF: Int64 = capture.offersTIFF ? 1 : 0
        let offersPlainText: Int64 = capture.offersPlainText ? 1 : 0
        if let id = try db.first(Self.idForHashSQL, [.text(capture.hash)], map: { $0.int64(0) }) {
            try db.run(
                bumpSQL, [.double(seconds), .int(capture.byteSize), .int(offersTIFF), .int(offersPlainText), .int(id)]
            )
            if try !children(of: id, match: capture, db: db) {
                try db.run("DELETE FROM representations WHERE item_id = ?", [.int(id)])
                try db.run("DELETE FROM files WHERE item_id = ?", [.int(id)])
                try insertChildren(of: capture, id: id, db: db)
            }
            return .bumped(id)
        }
        try db.run(
            insertSQL,
            [
                .text(capture.hash),
                .int(Int64(capture.kind.rawValue)),
                .double(seconds),
                .text(capture.title),
                capture.detail.map(SQLValue.text) ?? .null,
                .text(capture.searchText),
                .int(capture.byteSize),
                capture.blob.map { SQLValue.text($0.type) } ?? .null,
                .int(Int64(capture.files.count)),
                .int(offersTIFF),
                .int(offersPlainText),
            ]
        )
        let id = db.lastInsertRowID
        try insertChildren(of: capture, id: id, db: db)
        return .inserted(id)
    }

    /// Returns true when the stored formats and file references already equal the capture's. A
    /// repeat copy then has nothing to rewrite. SQLite compares the bytes without handing them to
    /// Swift.
    private static func children(of id: Int64, match capture: Capture, db: Database) throws -> Bool {
        let counts = try db.first(
            "SELECT (SELECT count(*) FROM representations WHERE item_id = ?1), (SELECT count(*) FROM files WHERE item_id = ?1)",
            [.int(id)]
        ) { (Int($0.int64(0)), Int($0.int64(1))) }
        guard let counts, counts == (capture.representations.count, capture.files.count) else { return false }
        for (position, representation) in capture.representations.enumerated() {
            let same = try db.first(
                "SELECT 1 FROM representations WHERE item_id = ? AND position = ? AND type = ? AND data = ?",
                [.int(id), .int(Int64(position)), .text(representation.type), .blob(representation.data)]
            ) { _ in true }
            if same == nil { return false }
        }
        for (position, file) in capture.files.enumerated() {
            let same = try db.first(
                "SELECT 1 FROM files WHERE item_id = ? AND position = ? AND path = ? AND bookmark IS ?",
                [.int(id), .int(Int64(position)), .text(file.path), file.bookmark.map(SQLValue.blob) ?? .null]
            ) { _ in true }
            if same == nil { return false }
        }
        return true
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

    /// An item moves to the top when the user copies it again from the panel or the menu.
    func touch(id: Int64, at date: Date = Date()) async throws {
        try await perform { db in
            try db.run(Self.touchSQL, [.double(try Self.copyTime(for: date, db: db)), .int(id)])
        }
    }

    /// Returns the time to store for a copy made at `date`. This time is later than the stored time
    /// of every earlier copy. The list is ordered by this time, and the search index is ordered by
    /// sequence number. The two orders match only if every copy has a later time than every older
    /// copy. The clock can step back, so `date` alone does not keep the orders the same.
    private static func copyTime(for date: Date, db: Database) throws -> Double {
        let seconds = date.timeIntervalSince1970
        guard let newest = try db.first(newestTimeSQL, map: { $0.double(0) }) else { return seconds }
        return max(seconds, newest.nextUp)
    }

    /// The method saves a thumbnail unless the row with this hash was deleted during thumbnail
    /// creation. It returns true when it saves the thumbnail. A save that fails leaves the row and
    /// any thumbnail it already had as they were.
    @discardableResult
    func saveThumbnail(_ png: Data, for hash: String) async throws -> Bool {
        guard !png.isEmpty else { return false }
        let staged = try await stage(png)
        return try await perform { db in
            let path = self.thumbPrefix + hash + ".png"
            var replacesUnrecorded = false
            var inPlace = false
            let saved: Bool
            do {
                saved = try db.transaction {
                    guard let owner = try db.first(Self.thumbnailOwnerSQL, [.text(hash)], map: { ($0.int64(0), $0.int64(1)) }) else {
                        return false
                    }
                    replacesUnrecorded = owner.1 == 0
                    try db.run("UPDATE items SET thumb_size = ? WHERE id = ?", [.int(Int64(png.count)), .int(owner.0)])
                    try self.move(staged, to: path)
                    inPlace = true
                    return true
                }
            } catch {
                // A thumbnail on disk always has its size recorded, so the file is removed when its
                // size could not be committed.
                if inPlace, replacesUnrecorded { unlink(path) }
                if !inPlace { unlink(staged) }
                throw error
            }
            guard saved else {
                unlink(staged)
                return false
            }
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
            removed += batch
            if batch < Constants.Storage.evictionBatch { return removed }
        }
    }

    /// The history tracks the size in bytes of text and its formatting, image data, and thumbnails.
    /// Reading the total requires one row. Triggers keep the counter current.
    func storageUsage() async throws -> Int64 {
        try await perform { db in try Self.totalBytes(db) }
    }

    private func evictWhileOverBudget(_ db: Database) throws {
        guard budgetBytes != nil else { return }
        while try evictBatch(db) == Constants.Storage.evictionBatch {}
    }

    /// It removes up to one batch of the oldest items while the history exceeds its limit. It reads
    /// the oldest items first using the `items_recent` index, so each row costs O(log n). It never
    /// removes the newest row. It returns the number of rows removed.
    private func evictBatch(_ db: Database) throws -> Int {
        guard let budget = budgetBytes else { return 0 }
        let total = try Self.totalBytes(db)
        guard total > budget, let newest = try db.first(Self.newestSQL, map: { $0.int64(0) }) else { return 0 }
        let candidates = try db.query(Self.oldestSQL, [.int(Int64(Constants.Storage.evictionBatch))]) {
            EvictionCandidate(
                id: $0.int64(0), hash: $0.string(1) ?? "", bytes: $0.int64(2), hasBlob: $0.int64(3) != 0,
                hasThumbnail: $0.int64(4) != 0
            )
        }
        let plan = EvictionPlan.select(from: candidates, excess: total - budget, keeping: newest)
        guard !plan.isEmpty else { return 0 }
        let ids = "[" + plan.map { String($0.id) }.joined(separator: ",") + "]"
        try db.transaction { try db.run(Self.evictSQL, [.text(ids)]) }
        for candidate in plan {
            removeFiles(named: candidate.hash, blob: candidate.hasBlob, thumbnail: candidate.hasThumbnail)
        }
        let freed = plan.reduce(0) { $0 + $1.bytes }
        Log.store.info("Removed \(plan.count) items (\(freed) bytes) to stay under the storage limit")
        return plan.count
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
            // A commit reaches the disk only at a checkpoint. A session that loses power must
            // still read as unclean, or the files it orphaned are never swept.
            try? db.execute("PRAGMA wal_checkpoint(PASSIVE)")
            return clean
        }
    }

    /// This records an orderly shutdown and waits for the queue because the app is terminating. A
    /// continuation would receive nothing. The checkpoint moves the session's commits from the log
    /// into the database file and syncs the file. Thus, the history survives a loss of power after
    /// the app quits.
    func markCleanShutdown() {
        queue.sync {
            do {
                try db.run("UPDATE stats SET clean_shutdown = 1 WHERE id = 1")
                try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
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
            var reader = RowReader(blobPrefix: self.blobPrefix)
            if let cursor {
                return try db.query(
                    Self.pageAfterSQL,
                    [.double(cursor.lastUsed.timeIntervalSince1970), .int(cursor.id), .int(Int64(limit))]
                ) { reader.item(from: $0) }
            }
            return try db.query(Self.pageSQL, [.int(Int64(limit))]) { reader.item(from: $0) }
        }
    }

    /// The full-text search treats every word as a prefix and returns the most recently copied
    /// matches first. Pass the last row shown to get the next page. The index lists matches in that
    /// order, so a page reads only the rows it returns.
    func search(_ text: String, after cursor: PageCursor? = nil, limit: Int = Constants.List.pageSize) async throws -> [ClipItem] {
        guard let match = Self.ftsQuery(from: text) else { return [] }
        return try await perform { db in
            var bound = Int64.max
            if let cursor {
                guard let older = try Self.sequence(before: cursor, db: db) else { return [] }
                bound = older
            }
            var reader = RowReader(blobPrefix: self.blobPrefix)
            return try db.query(Self.searchSQL, [.text(match), .int(bound), .int(Int64(limit))]) { reader.item(from: $0) }
        }
    }

    /// Returns the highest sequence number that any row copied before the cursor row can hold, or
    /// nil if no older row exists. If the cursor row was copied again or removed after it was
    /// shown, the newest row with an older date marks its old place.
    private static func sequence(before cursor: PageCursor, db: Database) throws -> Int64? {
        let lastUsed = cursor.lastUsed.timeIntervalSince1970
        if let seq = try db.first(cursorSequenceSQL, [.int(cursor.id), .double(lastUsed)], map: { $0.int64(0) }) {
            return seq - 1
        }
        return try db.first(sequenceBeforeSQL, [.double(lastUsed), .int(cursor.id)]) { $0.int64(0) }
    }

    func count() async throws -> Int {
        try await perform { db in Int(try db.scalarInt(Self.countSQL) ?? 0) }
    }

    func payload(for id: Int64) async throws -> ClipPayload? {
        let stored: StoredPayload? = try await perform { db in
            let item = try db.first(Self.payloadSQL, [.int(id)]) { row in
                (
                    kind: ClipKind(rawValue: Int(row.int64(0))) ?? .text, searchText: row.string(1) ?? "",
                    hash: row.string(2) ?? "", blobType: row.string(3), offersTIFF: row.int64(4) != 0,
                    offersPlainText: row.int64(5) != 0, fileCount: row.int64(6)
                )
            }
            guard let item else { return nil }
            let representations = try db.query(
                "SELECT type, data FROM representations WHERE item_id = ? ORDER BY position", [.int(id)]
            ) { PasteboardRepresentation(type: $0.string(0) ?? "", data: $0.data(1) ?? Data()) }
            var files: [FileReference] = []
            if item.fileCount > 0 {
                files = try db.query(
                    "SELECT path, bookmark FROM files WHERE item_id = ? ORDER BY position", [.int(id)]
                ) { FileReference(path: $0.string(0) ?? "", bookmark: $0.data(1)) }
            }
            return StoredPayload(
                kind: item.kind, plainText: item.kind == .text && item.offersPlainText ? item.searchText : nil,
                representations: representations, files: files, hash: item.hash, blobType: item.blobType,
                offersTIFF: item.offersTIFF
            )
        }
        guard let stored else { return nil }
        guard let blobType = stored.blobType else {
            return ClipPayload(
                kind: stored.kind, plainText: stored.plainText, representations: stored.representations,
                files: stored.files, blob: nil
            )
        }
        let path = blobPrefix + stored.hash
        return await withCheckedContinuation { continuation in
            fileQueue.async {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path, isDirectory: false)) else {
                    Log.store.error("Blob for item \(id) is missing")
                    continuation.resume(returning: nil)
                    return
                }
                var restored = stored.representations
                if stored.offersTIFF, blobType != PasteboardTypes.tiff, let tiff = ImageProcessing.tiffData(from: data) {
                    restored.insert(PasteboardRepresentation(type: PasteboardTypes.tiff, data: tiff), at: 0)
                }
                continuation.resume(returning: ClipPayload(
                    kind: stored.kind, plainText: stored.plainText, representations: restored, files: stored.files,
                    blob: PasteboardRepresentation(type: blobType, data: data)
                ))
            }
        }
    }

    /// The database stores this part of a payload.
    private struct StoredPayload: Sendable {
        let kind: ClipKind
        let plainText: String?
        let representations: [PasteboardRepresentation]
        let files: [FileReference]
        let hash: String
        let blobType: String?
        let offersTIFF: Bool
    }

    /// The preview pane shows more of the start of an item's text than the row preview. The read
    /// stops after the maximum bytes for that number of characters, so it does not load the rest of
    /// a long text.
    func textPreview(for id: Int64, maxCharacters: Int = Constants.List.detailPreviewCharacters) async throws -> String {
        let limit = max(maxCharacters, 0)
        return try await perform { db in
            let bytes = try db.prefix(ofColumn: "search_text", inTable: "items", rowID: id, maxBytes: limit * 4)
            guard let bytes else { return "" }
            let text = String(decoding: bytes, as: UTF8.self)
            guard text.unicodeScalars.count > limit else { return text }
            return String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
        }
    }

    func schemaVersionOnDisk() async throws -> Int {
        try await perform { db in try db.userVersion() }
    }

    // MARK: - Clearing

    func count(matching request: ClearRequest) async throws -> Int {
        guard let (clause, values) = Self.predicate(for: request) else { return 0 }
        return try await perform { db in
            Int(try db.scalarInt(clause.isEmpty ? Self.countSQL : "SELECT count(*) FROM items WHERE \(clause)", values) ?? 0)
        }
    }

    /// It deletes the matching rows, then deletes the blob and thumbnail of each deleted row.
    @discardableResult
    func clear(_ request: ClearRequest) async throws -> Int {
        guard let (clause, values) = Self.predicate(for: request) else { return 0 }
        return try await perform { db in
            let (count, owners): (Int, [(String, Bool, Bool)]) = try db.transaction {
                let owners = try db.query(Self.fileOwnersSQL(where: clause), values) {
                    ($0.string(0) ?? "", $0.int64(1) != 0, $0.int64(2) != 0)
                }
                if clause.isEmpty {
                    // When the index is empty, removing each row's entry does nothing.
                    try db.run("INSERT INTO items_fts (items_fts) VALUES ('delete-all')")
                }
                try db.run(Self.deleteSQL(where: clause), values)
                return (db.changes, owners)
            }
            for (hash, hasBlob, hasThumbnail) in owners {
                self.removeFiles(named: hash, blob: hasBlob, thumbnail: hasThumbnail)
            }
            Log.store.info("Cleared \(count) items")
            return count
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
                let url = directory.appendingPathComponent(name, isDirectory: false)
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
            lookup.reset()
        }
        return removed
    }

    // MARK: - Query helpers

    /// This builds an FTS5 query that treats every word as a prefix. It quotes each word, so the
    /// query searches for user-entered FTS operators as text.
    static func ftsQuery(from text: String) -> String? {
        // SQLite reads the query only up to a NUL, which would cut off part of a quoted word.
        let words = text.split { $0.isWhitespace || $0 == "\u{0}" }
            .map(String.init)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " ")
    }

    /// The clause is empty when the request covers every row.
    private static func predicate(for request: ClearRequest) -> (String, [SQLValue])? {
        guard !request.kinds.isEmpty else { return nil }
        guard let cutoff = request.cutoff else {
            // Every row has one of the kinds, so a request for all of them needs no kind test.
            if request.kinds.count == ClipKind.allCases.count { return ("", []) }
            return ("kind IN (\(kindList(request.kinds)))", [])
        }
        return ("kind IN (\(kindList(request.kinds))) AND last_used >= ?", [.double(cutoff.timeIntervalSince1970)])
    }

    private static func kindList(_ kinds: Set<ClipKind>) -> String {
        kinds.map { String($0.rawValue) }.sorted().joined(separator: ", ")
    }

    /// A row keeps the first `Constants.List.rowPreviewCharacters` characters of its text in
    /// `preview` when the text has more bytes than that number. A list read then never loads a long
    /// text. `length` stops at a NUL, so the byte test cannot use it.
    private static let itemColumns = """
        items.id, items.hash, items.kind, items.created_at, items.last_used, items.title, items.detail, \
        coalesce(items.preview, items.search_text), items.byte_size, items.blob_type, items.file_count
        """
    /// The row with the highest sequence number keeps its number. Any other row takes the next
    /// number, which moves its entry in the search index to the front.
    private static let nextSequenceSQL = """
        CASE WHEN seq = (SELECT max(seq) FROM items) THEN seq ELSE (SELECT max(seq) FROM items) + 1 END
        """

    static let pageSQL = "SELECT \(itemColumns) FROM items ORDER BY last_used DESC, id DESC LIMIT ?"
    static let pageAfterSQL = """
        SELECT \(itemColumns) FROM items WHERE (last_used, id) < (?, ?) ORDER BY last_used DESC, id DESC LIMIT ?
        """
    static let insertSQL = """
        INSERT INTO items (hash, kind, created_at, last_used, seq, title, detail, preview, search_text, byte_size, blob_type, file_count, offers_tiff, offers_plain_text)
        VALUES (?1, ?2, ?3, ?3, coalesce((SELECT max(seq) FROM items), 0) + 1, ?4, ?5,
            CASE WHEN octet_length(?6) > \(Constants.List.rowPreviewCharacters) THEN substr(?6, 1, \(Constants.List.rowPreviewCharacters)) END,
            ?6, ?7, ?8, ?9, ?10, ?11)
        """
    static let idForHashSQL = "SELECT id FROM items WHERE hash = ?"
    static let thumbnailOwnerSQL = "SELECT id, thumb_size FROM items WHERE hash = ?"
    static let newestTimeSQL = "SELECT last_used FROM items ORDER BY last_used DESC, id DESC LIMIT 1"
    static let bumpSQL = """
        UPDATE items SET last_used = ?1, seq = \(nextSequenceSQL), byte_size = ?2, offers_tiff = ?3, offers_plain_text = ?4
        WHERE id = ?5
        """
    static let touchSQL = "UPDATE items SET last_used = ?1, seq = \(nextSequenceSQL) WHERE id = ?2"
    /// The index holds one entry per row, keyed by the row's sequence number. Thus, the index order
    /// determines the result order, and the scan stops after one page.
    static let searchSQL = """
        SELECT \(itemColumns) FROM items_fts CROSS JOIN items ON items.seq = items_fts.rowid
        WHERE items_fts MATCH ?1 AND items_fts.rowid <= ?2
        ORDER BY items_fts.rowid DESC LIMIT ?3
        """
    static let cursorSequenceSQL = "SELECT seq FROM items WHERE id = ? AND last_used = ?"
    static let sequenceBeforeSQL = """
        SELECT seq FROM items WHERE (last_used, id) < (?, ?) ORDER BY last_used DESC, id DESC LIMIT 1
        """
    static let payloadSQL = """
        SELECT kind, search_text, hash, blob_type, offers_tiff, offers_plain_text, file_count FROM items WHERE id = ?
        """
    static let countSQL = "SELECT count(*) FROM items"
    static let totalBytesSQL = "SELECT total_bytes FROM stats WHERE id = 1"
    static let newestSQL = "SELECT id FROM items ORDER BY last_used DESC, id DESC LIMIT 1"
    /// This is the number of bytes a row uses on disk. A file item stores a reference and a
    /// thumbnail, but it does not store the file itself.
    static let storedBytesSQL = "(CASE WHEN kind = \(ClipKind.file.rawValue) THEN 0 ELSE byte_size END) + thumb_size"
    /// This identifies which rows can have a blob or a thumbnail on disk and which one each row can
    /// have. An image or a file may have a thumbnail on disk with no size in its row after a crash.
    /// This state lasts until the sweep records the size. It may also occur in a history written by
    /// an earlier version.
    static func fileOwnersSQL(where clause: String) -> String {
        "SELECT hash, \(hasFilesSQL) FROM items WHERE (kind <> \(ClipKind.text.rawValue) OR blob_type IS NOT NULL OR thumb_size > 0)\(clause.isEmpty ? "" : " AND (\(clause))")"
    }

    private static let hasFilesSQL = "blob_type IS NOT NULL, thumb_size > 0 OR kind <> \(ClipKind.text.rawValue)"
    /// Rows leave in sequence number order. The search index writes its pending changes to disk
    /// whenever a removal arrives out of that order.
    static func deleteSQL(where clause: String) -> String {
        "DELETE FROM items WHERE seq IN (SELECT seq FROM items\(clause.isEmpty ? "" : " WHERE \(clause)"))"
    }

    /// It uses one statement to remove the rows whose IDs are listed in the JSON array.
    static let evictSQL = deleteSQL(where: "id IN (SELECT value FROM json_each(?))")
    static let oldestSQL = "SELECT id, hash, \(storedBytesSQL), \(hasFilesSQL) FROM items ORDER BY last_used ASC, id ASC LIMIT ?"

    /// It maps list rows and reads the mount table only when a page contains a file item.
    private struct RowReader {
        let blobPrefix: String
        private var volumes: LocalVolumes?

        init(blobPrefix: String) {
            self.blobPrefix = blobPrefix
        }

        mutating func item(from row: Statement) -> ClipItem {
            let kind = ClipKind(rawValue: Int(row.int64(2))) ?? .text
            let hash = row.string(1) ?? ""
            let detail = row.string(6)
            let isMissing: Bool
            switch kind {
            case .file:
                if let detail {
                    let mounted = volumes ?? LocalVolumes.current()
                    volumes = mounted
                    isMissing = mounted.isMissing(atPath: detail)
                } else {
                    isMissing = true
                }
            case .image:
                isMissing = access(blobPrefix + hash, F_OK) != 0
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
    }

    // MARK: - Files

    /// Writes the bytes to a new file in the staging directory, off the store queue, and returns
    /// its path.
    private func stage(_ data: Data) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            fileQueue.async {
                continuation.resume(with: Result { try self.writeStaged(data) })
            }
        }
    }

    /// The store's directories are empty much of the time, so a cleanup tool may remove one. After
    /// a write fails, the code creates the directory and retries the write once.
    private func writeStaged(_ data: Data) throws -> String {
        let path = stagingPrefix + UUID().uuidString
        let url = URL(fileURLWithPath: path, isDirectory: false)
        do {
            try data.write(to: url)
        } catch {
            do {
                try FileManager.default.createDirectory(at: location.staging, withIntermediateDirectories: true)
                try data.write(to: url)
            } catch {
                unlink(path)
                throw error
            }
        }
        return path
    }

    /// The capture's blob is staged unless a file with its hash already exists.
    private func stageBlob(of capture: Capture) async throws -> String? {
        guard let blob = capture.blob, access(blobPrefix + capture.hash, F_OK) != 0 else { return nil }
        return try await stage(blob.data)
    }

    /// This code puts the capture's blob in place on the store queue before the row that names it
    /// exists. A blob that was in place when the capture arrived may have been evicted since then.
    /// This code writes it here when it is missing and nothing was staged.
    private func adoptBlob(of capture: Capture, stagedAt staged: String?) throws {
        guard let blob = capture.blob else { return }
        let path = blobPrefix + capture.hash
        if let staged {
            try move(staged, to: path)
        } else if access(path, F_OK) != 0 {
            try move(try writeStaged(blob.data), to: path)
        }
    }

    private func move(_ staged: String, to path: String) throws {
        if rename(staged, path) == 0 { return }
        var code = errno
        if code == ENOENT {
            let directory = URL(fileURLWithPath: path, isDirectory: false).deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if rename(staged, path) == 0 { return }
            code = errno
        }
        unlink(staged)
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// Removes the files of a row that was just deleted. The hash is unique, so no other row
    /// names them.
    private func removeFiles(named hash: String, blob: Bool, thumbnail: Bool) {
        if blob { unlink(blobPrefix + hash) }
        if thumbnail { unlink(thumbPrefix + hash + ".png") }
    }

    /// This records the size of every thumbnail made before thumbnail counting began. It runs once
    /// when a database older than version 4 opens.
    private static func recordThumbnailSizes(_ db: Database, location: StoreLocation) throws {
        let rows = try db.query(
            "SELECT id, hash FROM items WHERE kind != ?", [.int(Int64(ClipKind.text.rawValue))]
        ) { ($0.int64(0), $0.string(1) ?? "") }
        try db.transaction {
            for (id, hash) in rows {
                let size = PasteboardClassifier.size(ofFileAt: location.thumbnailURL(for: hash).path)
                guard size > 0 else { continue }
                try db.run("UPDATE items SET thumb_size = ? WHERE id = ?", [.int(size), .int(id)])
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
        try db.execute("PRAGMA wal_autocheckpoint = \(Constants.Storage.checkpointPages)")
        // The log file is kept at this size and overwritten, which costs less than growing it
        // again after each checkpoint.
        try db.execute("PRAGMA journal_size_limit = \(Constants.Storage.logSizeLimit)")
    }

    /// The schema advances one version at a time. Each step runs in its own transaction. `target`
    /// is below `schemaVersion` only in tests that build an older database.
    static func migrate(_ db: Database, upTo target: Int = schemaVersion) throws {
        let current = try db.userVersion()
        guard current <= schemaVersion else { throw StoreError.newerSchema(current) }
        guard current < target else { return }
        for version in current..<target {
            // Dropping a table deletes its rows, and that would cascade to the rows that refer to
            // them. The setting changes only outside a transaction.
            let rebuildsItems = version == 4
            if rebuildsItems { try db.execute("PRAGMA foreign_keys = OFF") }
            defer {
                if rebuildsItems { try? db.execute("PRAGMA foreign_keys = ON") }
            }
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
        case 4:
            // Search reads matches in index order, so the index key is a sequence number that grows
            // with each copy. The text moves to the end of the row, behind a short preview, so a
            // list read stops before it. No step sorts the texts: the numbers come from a table of
            // ids, and the fill follows the order of the index's own keys. The fill keeps more of
            // the index in memory than a single copy needs, so it writes fewer and larger pieces.
            // The setting then goes back to the default. Foreign keys are off during this step, so
            // rows that refer to no item are removed by hand.
            try db.execute("""
                CREATE TABLE items_v5 (
                    id INTEGER PRIMARY KEY,
                    hash TEXT NOT NULL UNIQUE,
                    kind INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    last_used REAL NOT NULL,
                    seq INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    detail TEXT,
                    preview TEXT,
                    byte_size INTEGER NOT NULL,
                    blob_type TEXT,
                    file_count INTEGER NOT NULL DEFAULT 0,
                    offers_tiff INTEGER NOT NULL DEFAULT 0,
                    offers_plain_text INTEGER NOT NULL DEFAULT 1,
                    thumb_size INTEGER NOT NULL DEFAULT 0,
                    search_text TEXT NOT NULL
                );
                CREATE TEMP TABLE items_order (id INTEGER PRIMARY KEY, seq INTEGER NOT NULL);
                INSERT INTO items_order (id, seq) SELECT id, row_number() OVER (ORDER BY last_used, id) FROM items;
                INSERT INTO items_v5 (
                    id, hash, kind, created_at, last_used, seq, title, detail, preview, byte_size, blob_type,
                    file_count, offers_tiff, offers_plain_text, thumb_size, search_text
                )
                SELECT id, hash, kind, created_at, last_used, (SELECT seq FROM items_order WHERE items_order.id = items.id),
                    title, detail, CASE WHEN octet_length(search_text) > 300 THEN substr(search_text, 1, 300) END, byte_size,
                    blob_type, file_count, offers_tiff, offers_plain_text, thumb_size, search_text
                FROM items;
                DROP TABLE items_order;
                DROP TABLE items_fts;
                DROP TABLE items;
                ALTER TABLE items_v5 RENAME TO items;
                DELETE FROM representations WHERE item_id NOT IN (SELECT id FROM items);
                DELETE FROM files WHERE item_id NOT IN (SELECT id FROM items);
                CREATE INDEX items_recent ON items (last_used DESC, id DESC);
                CREATE INDEX items_kind_recent ON items (kind, last_used);
                CREATE UNIQUE INDEX items_seq ON items (seq);
                CREATE VIRTUAL TABLE items_fts USING fts5 (
                    search_text, content = '', contentless_delete = 1, prefix = '2 3',
                    tokenize = 'unicode61 remove_diacritics 2'
                );
                INSERT INTO items_fts (items_fts, rank) VALUES ('hashsize', 8388608);
                INSERT INTO items_fts (rowid, search_text)
                SELECT seq, search_text FROM items INDEXED BY items_seq ORDER BY seq;
                INSERT INTO items_fts (items_fts, rank) VALUES ('hashsize', 1048576);
                CREATE TRIGGER items_fts_insert AFTER INSERT ON items BEGIN
                    INSERT INTO items_fts (rowid, search_text) VALUES (new.seq, new.search_text);
                END;
                CREATE TRIGGER items_fts_delete AFTER DELETE ON items BEGIN
                    DELETE FROM items_fts WHERE rowid = old.seq;
                END;
                CREATE TRIGGER items_fts_move AFTER UPDATE OF seq ON items WHEN old.seq <> new.seq BEGIN
                    DELETE FROM items_fts WHERE rowid = old.seq;
                    INSERT INTO items_fts (rowid, search_text) VALUES (new.seq, new.search_text);
                END;
                CREATE TRIGGER items_fts_update AFTER UPDATE OF search_text ON items WHEN old.seq = new.seq BEGIN
                    DELETE FROM items_fts WHERE rowid = old.seq;
                    INSERT INTO items_fts (rowid, search_text) VALUES (new.seq, new.search_text);
                END;
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

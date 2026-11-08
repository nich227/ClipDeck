import XCTest
@testable import ClipDeck

final class ClipStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ClipStore!

    override func setUpWithError() throws {
        directory = Fixtures.temporaryDirectory()
        store = try ClipStore(location: StoreLocation(root: directory))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + offset)
    }

    // MARK: - Insert and dedup

    func testInsertedItemsComeBackNewestFirst() async throws {
        _ = try await store.insert(Fixtures.textCapture("first"), at: date(1))
        _ = try await store.insert(Fixtures.textCapture("second"), at: date(2))
        _ = try await store.insert(Fixtures.textCapture("third"), at: date(3))

        let page = try await store.page()
        XCTAssertEqual(page.map(\.title), ["third", "second", "first"])
        XCTAssertEqual(page.first?.kind, .text)
        XCTAssertEqual(page.first?.preview, "third")
    }

    func testDuplicateBumpsInsteadOfInserting() async throws {
        let first = try await store.insert(Fixtures.textCapture("alpha"), at: date(1))
        _ = try await store.insert(Fixtures.textCapture("beta"), at: date(2))
        let again = try await store.insert(Fixtures.textCapture("alpha"), at: date(3))

        guard case .inserted(let id) = first else { return XCTFail("first insert should insert") }
        XCTAssertEqual(again, .bumped(id))
        let count = try await store.count()
        XCTAssertEqual(count, 2)
        let page = try await store.page()
        XCTAssertEqual(page.map(\.title), ["alpha", "beta"])
        XCTAssertEqual(page.first?.createdAt, date(1))
        XCTAssertEqual(page.first?.lastUsed, date(3))
    }

    func testRepeatCopyReplacesTheStoredFormats() async throws {
        let rtf = Data("{\\rtf1 styled}".utf8)
        let first = try await store.insert(Fixtures.textCapture("foo", rtf: rtf), at: date(1))
        let before = try await store.payload(for: first.id)
        XCTAssertEqual(before?.representations.map(\.type), [PasteboardTypes.rtf])

        let again = try await store.insert(Fixtures.textCapture("foo"), at: date(2))
        XCTAssertEqual(again, .bumped(first.id))
        let after = try await store.payload(for: first.id)
        XCTAssertEqual(after?.representations, [])
        XCTAssertEqual(after?.plainText, "foo")
    }

    func testRepeatCopyWithoutPlainTextDropsTheStoredPlainText() async throws {
        let first = try await store.insert(Fixtures.textCapture("bar"), at: date(1))
        guard case .capture(let htmlOnly) = Fixtures.classifier().classify(
            Fixtures.snapshot([[PasteboardTypes.html: Data("<b>bar</b>".utf8)]])
        ) else { return XCTFail("html did not classify") }
        XCTAssertEqual(htmlOnly.hash, Fixtures.textCapture("bar").hash)

        let again = try await store.insert(htmlOnly, at: date(2))
        XCTAssertEqual(again, .bumped(first.id))
        let payload = try await store.payload(for: first.id)
        XCTAssertNil(payload?.plainText)
        XCTAssertEqual(payload?.representations.map(\.type), [PasteboardTypes.html])
    }

    func testImageWithMissingBlobShowsAsMissing() async throws {
        let image = Fixtures.imageCapture()
        let outcome = try await store.insert(image)
        let present = try await store.page()
        XCTAssertEqual(present.first?.isMissing, false)

        try FileManager.default.removeItem(at: store.location.blobURL(for: image.hash))
        let missing = try await store.page()
        XCTAssertEqual(missing.first?.isMissing, true)
        let payload = try await store.payload(for: outcome.id)
        XCTAssertNil(payload)
    }

    func testTouchMovesItemToTop() async throws {
        let old = try await store.insert(Fixtures.textCapture("old"), at: date(1))
        _ = try await store.insert(Fixtures.textCapture("new"), at: date(2))
        try await store.touch(id: old.id, at: date(3))

        let titles = try await store.page().map(\.title)
        XCTAssertEqual(titles, ["old", "new"])
    }

    // MARK: - Paging

    func testCursorPagingCoversEveryRowOnce() async throws {
        for index in 0..<250 {
            _ = try await store.insert(Fixtures.textCapture("item \(index)"), at: date(TimeInterval(index)))
        }

        var seen: [String] = []
        var cursor: PageCursor?
        var pageSizes: [Int] = []
        repeat {
            let page = try await store.page(after: cursor, limit: 100)
            pageSizes.append(page.count)
            seen += page.map(\.title)
            cursor = page.last.map(PageCursor.init(after:))
        } while pageSizes.last == 100

        XCTAssertEqual(pageSizes, [100, 100, 50])
        XCTAssertEqual(seen.count, 250)
        XCTAssertEqual(Set(seen).count, 250)
        XCTAssertEqual(seen.first, "item 249")
        XCTAssertEqual(seen.last, "item 0")
    }

    func testCursorPagingBreaksTiesById() async throws {
        for index in 0..<5 {
            _ = try await store.insert(Fixtures.textCapture("same time \(index)"), at: date(0))
        }
        let first = try await store.page(limit: 2)
        let second = try await store.page(after: PageCursor(after: first[1]), limit: 10)
        XCTAssertEqual(first.count + second.count, 5)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
    }

    // MARK: - Search

    func testSearchMatchesWordPrefixes() async throws {
        _ = try await store.insert(Fixtures.textCapture("hello world"), at: date(1))
        _ = try await store.insert(Fixtures.textCapture("help desk ticket"), at: date(2))
        _ = try await store.insert(Fixtures.textCapture("goodbye"), at: date(3))

        let hel = try await store.search("hel")
        XCTAssertEqual(hel.map(\.title), ["help desk ticket", "hello world"])
        let both = try await store.search("hel wor")
        XCTAssertEqual(both.map(\.title), ["hello world"])
        let none = try await store.search("xyz")
        XCTAssertTrue(none.isEmpty)
    }

    func testSearchTreatsOperatorsAsText() async throws {
        _ = try await store.insert(Fixtures.textCapture("say \"quoted\" NOT here"), at: date(1))
        let results = try await store.search("\"quo NOT")
        XCTAssertEqual(results.count, 1)
        let punctuation = try await store.search("-- **")
        XCTAssertTrue(punctuation.isEmpty)
    }

    func testSearchFindsFilesByName() async throws {
        _ = try await store.insert(Fixtures.fileCapture(["/tmp/Quarterly Report.pdf"]), at: date(1))
        let results = try await store.search("quart")
        XCTAssertEqual(results.first?.kind, .file)
        XCTAssertEqual(results.first?.title, "Quarterly Report.pdf")
    }

    func testSearchPagesByCursor() async throws {
        for index in 0..<120 {
            _ = try await store.insert(Fixtures.textCapture("needle \(index)"), at: date(TimeInterval(index)))
        }
        let first = try await store.search("needle", limit: 100)
        let last = try XCTUnwrap(first.last)
        let second = try await store.search("needle", after: PageCursor(after: last), limit: 100)
        XCTAssertEqual(first.count, 100)
        XCTAssertEqual(second.count, 20)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
        XCTAssertEqual(first.first?.title, "needle 119")
        XCTAssertEqual(second.last?.title, "needle 0")
    }

    func testFTSQueryQuotesEveryWordAsPrefix() {
        XCTAssertEqual(ClipStore.ftsQuery(from: "foo bar"), "\"foo\"* \"bar\"*")
        XCTAssertEqual(ClipStore.ftsQuery(from: "say\"hi"), "\"say\"\"hi\"*")
        XCTAssertNil(ClipStore.ftsQuery(from: "   "))
        XCTAssertNil(ClipStore.ftsQuery(from: "- *"))
    }

    // MARK: - Payloads

    func testTextPayloadKeepsOriginalTypes() async throws {
        let rtf = Data("{\\rtf1 rich}".utf8)
        let id = try await store.insert(Fixtures.textCapture("rich", rtf: rtf)).id
        let payload = try await store.payload(for: id)
        XCTAssertEqual(payload?.plainText, "rich")
        XCTAssertEqual(payload?.representations, [PasteboardRepresentation(type: PasteboardTypes.rtf, data: rtf)])
    }

    func testFilePayloadKeepsPathsAndBookmarks() async throws {
        let id = try await store.insert(Fixtures.fileCapture(["/tmp/a.txt", "/tmp/b.txt"])).id
        let payload = try await store.payload(for: id)
        XCTAssertEqual(payload?.files.map(\.path), ["/tmp/a.txt", "/tmp/b.txt"])
        XCTAssertEqual(payload?.files.first?.bookmark, Data("bookmark:/tmp/a.txt".utf8))
        XCTAssertNil(payload?.blob)
    }

    func testMissingFileIsFlagged() async throws {
        _ = try await store.insert(Fixtures.fileCapture(["/nonexistent/\(UUID().uuidString).mov"]))
        let page = try await store.page()
        XCTAssertEqual(page.first?.isMissing, true)
    }

    func testImageBytesAreStoredAsContentAddressedBlob() async throws {
        let capture = Fixtures.imageCapture()
        let id = try await store.insert(capture).id
        let blobURL = store.location.blobURL(for: capture.hash)
        XCTAssertEqual(try Data(contentsOf: blobURL), capture.blob?.data)
        let payload = try await store.payload(for: id)
        XCTAssertEqual(payload?.blob, capture.blob)
        XCTAssertEqual(payload?.blob?.type, PasteboardTypes.png)
    }

    func testImagePayloadKeepsCompanionsAndRebuildsTIFF() async throws {
        let html = Data("<img src=x>".utf8)
        guard case .capture(let capture) = Fixtures.classifier().classify(Fixtures.snapshot([[
            PasteboardTypes.tiff: Fixtures.tiff(width: 4, height: 4),
            PasteboardTypes.html: html,
        ]])) else { return XCTFail("image did not classify") }
        let id = try await store.insert(capture).id
        let fetched = try await store.payload(for: id)
        let payload = try XCTUnwrap(fetched)
        XCTAssertEqual(payload.blob?.type, PasteboardTypes.png)
        XCTAssertEqual(payload.representations.map(\.type), [PasteboardTypes.tiff, PasteboardTypes.html])
        let tiff = try XCTUnwrap(payload.representations.first?.data)
        XCTAssertEqual(ImageProcessing.pixelSize(of: tiff), CGSize(width: 4, height: 4))
    }

    func testPayloadIsNilWhenBlobIsGone() async throws {
        let capture = Fixtures.imageCapture()
        let id = try await store.insert(capture).id
        try FileManager.default.removeItem(at: store.location.blobURL(for: capture.hash))
        let payload = try await store.payload(for: id)
        XCTAssertNil(payload)
    }

    func testThumbnailForDeletedRowIsNotSaved() async throws {
        let image = Fixtures.imageCapture()
        _ = try await store.insert(image)
        try await store.clear(ClearRequest(range: .allTime, kinds: [.image]))
        let saved = try await store.saveThumbnail(Fixtures.png(width: 2, height: 2), for: image.hash)
        XCTAssertFalse(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location.thumbnailURL(for: image.hash).path))
    }

    // MARK: - Clearing

    func testClearByRangeAndKind() async throws {
        let now = date(100_000)
        _ = try await store.insert(Fixtures.textCapture("old text"), at: now.addingTimeInterval(-2 * 3600))
        _ = try await store.insert(Fixtures.textCapture("recent text"), at: now.addingTimeInterval(-600))
        _ = try await store.insert(Fixtures.imageCapture(), at: now.addingTimeInterval(-600))
        _ = try await store.insert(Fixtures.fileCapture(["/tmp/recent.txt"]), at: now.addingTimeInterval(-600))

        let request = ClearRequest(range: .lastHour, kinds: [.text], now: now)
        let preview = try await store.count(matching: request)
        XCTAssertEqual(preview, 1)
        let removed = try await store.clear(request)
        XCTAssertEqual(removed, 1)

        let titles = Set(try await store.page().map(\.title))
        XCTAssertFalse(titles.contains("recent text"))
        XCTAssertTrue(titles.contains("old text"))
        let remaining = try await store.count()
        XCTAssertEqual(remaining, 3)

        let everything = ClearRequest(range: .allTime, kinds: Set(ClipKind.allCases), now: now)
        let previewAll = try await store.count(matching: everything)
        XCTAssertEqual(previewAll, 3)
        try await store.clear(everything)
        let empty = try await store.count()
        XCTAssertEqual(empty, 0)
    }

    func testClearWithNoKindsRemovesNothing() async throws {
        _ = try await store.insert(Fixtures.textCapture("keep"))
        let request = ClearRequest(range: .allTime, kinds: [])
        let preview = try await store.count(matching: request)
        let removed = try await store.clear(request)
        XCTAssertEqual(preview, 0)
        XCTAssertEqual(removed, 0)
        let count = try await store.count()
        XCTAssertEqual(count, 1)
    }

    func testClearedItemsLeaveSearchIndex() async throws {
        _ = try await store.insert(Fixtures.textCapture("searchable gone"))
        try await store.clear(ClearRequest(range: .allTime, kinds: [.text]))
        let results = try await store.search("searchable")
        XCTAssertTrue(results.isEmpty)
    }

    func testClearRemovesUnreferencedBlobAndThumbnail() async throws {
        let image = Fixtures.imageCapture()
        _ = try await store.insert(image)
        try await store.saveThumbnail(Fixtures.png(width: 2, height: 2), for: image.hash)
        let blob = store.location.blobURL(for: image.hash)
        let thumb = store.location.thumbnailURL(for: image.hash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumb.path))

        try await store.clear(ClearRequest(range: .allTime, kinds: [.image]))

        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumb.path))
    }

    func testGarbageCollectionRemovesOnlyOrphans() async throws {
        let image = Fixtures.imageCapture()
        _ = try await store.insert(image)
        let orphanBlob = store.location.blobURL(for: "orphan")
        let orphanThumb = store.location.thumbnailURL(for: "orphan")
        try Data([1]).write(to: orphanBlob)
        try Data([1]).write(to: orphanThumb)

        let removed = try await store.collectGarbage()

        XCTAssertEqual(removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanBlob.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanThumb.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.location.blobURL(for: image.hash).path))
    }

    // MARK: - Stored bytes and the storage limit

    private func blobSize(_ capture: Capture) -> Int64 {
        Int64(capture.blob?.data.count ?? 0)
    }

    func testStoredBytesFollowInsertsBumpsClearsAndThumbnails() async throws {
        let text = Fixtures.textCapture("twelve bytes")
        let image = Fixtures.imageCapture(width: 64, height: 64)
        _ = try await store.insert(text, at: date(1))
        _ = try await store.insert(image, at: date(2))
        var used = try await store.storageUsage()
        XCTAssertEqual(used, text.byteSize + blobSize(image))

        let png = Fixtures.png(width: 8, height: 8)
        try await store.saveThumbnail(png, for: image.hash)
        used = try await store.storageUsage()
        XCTAssertEqual(used, text.byteSize + blobSize(image) + Int64(png.count))

        // When the copy repeats with richer formatting, the row grows, and the counter moves with
        // the row.
        let richer = Fixtures.textCapture("twelve bytes", rtf: Data("{\\rtf1 twelve bytes}".utf8))
        _ = try await store.insert(richer, at: date(3))
        used = try await store.storageUsage()
        XCTAssertEqual(used, richer.byteSize + blobSize(image) + Int64(png.count))

        try await store.clear(ClearRequest(range: .allTime, kinds: [.image]))
        used = try await store.storageUsage()
        XCTAssertEqual(used, richer.byteSize)
    }

    func testReferencedFilesCountOnlyTheirThumbnail() async throws {
        let file = Fixtures.fileCapture(["/tmp/large-video.mov"])
        XCTAssertGreaterThan(file.byteSize, 0, "the fixture reports a size for the referenced file")
        _ = try await store.insert(file)
        var used = try await store.storageUsage()
        XCTAssertEqual(used, 0)

        let png = Fixtures.png(width: 4, height: 4)
        try await store.saveThumbnail(png, for: file.hash)
        used = try await store.storageUsage()
        XCTAssertEqual(used, Int64(png.count))
    }

    func testLoweringTheLimitRemovesTheOldestItemsFirst() async throws {
        let images = (0..<4).map { Fixtures.imageCapture(width: 32 + $0, height: 32) }
        for (offset, image) in images.enumerated() {
            _ = try await store.insert(image, at: date(TimeInterval(offset)))
        }
        let sizes = images.map(blobSize)
        // There is room for the two newest, not three.
        let budget = sizes[2] + sizes[3] + (sizes[1] / 2)

        let removed = try await store.setStorageBudget(budget)

        XCTAssertEqual(removed, 2)
        let remaining = try await store.page().map(\.hash)
        XCTAssertEqual(remaining, [images[3].hash, images[2].hash])
        let used = try await store.storageUsage()
        XCTAssertLessThanOrEqual(used, budget)
        for gone in images[0...1] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.location.blobURL(for: gone.hash).path))
        }
        for kept in images[2...3] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.location.blobURL(for: kept.hash).path))
        }
    }

    func testInsertingOverTheLimitEvictsAtOnce() async throws {
        let first = Fixtures.imageCapture(width: 40, height: 40)
        let second = Fixtures.imageCapture(width: 48, height: 48)
        _ = try await store.setStorageBudget(blobSize(first) + blobSize(second) / 2)
        _ = try await store.insert(first, at: date(1))
        let countBefore = try await store.count()
        XCTAssertEqual(countBefore, 1)

        _ = try await store.insert(second, at: date(2))

        let remaining = try await store.page().map(\.hash)
        XCTAssertEqual(remaining, [second.hash])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location.blobURL(for: first.hash).path))
    }

    func testTheNewestItemSurvivesALimitSmallerThanItself() async throws {
        let only = Fixtures.imageCapture(width: 64, height: 64)
        _ = try await store.insert(only)
        let removed = try await store.setStorageBudget(1)
        XCTAssertEqual(removed, 0)
        let count = try await store.count()
        XCTAssertEqual(count, 1)
    }

    func testEvictionTouchesTheOldestByLastUsedNotByCreation() async throws {
        let old = Fixtures.imageCapture(width: 32, height: 32)
        let newer = Fixtures.imageCapture(width: 36, height: 36)
        _ = try await store.insert(old, at: date(1))
        _ = try await store.insert(newer, at: date(2))
        // Copying the old one again makes it the most recently used.
        _ = try await store.insert(old, at: date(3))

        _ = try await store.setStorageBudget(blobSize(old) + 1)

        let remaining = try await store.page().map(\.hash)
        XCTAssertEqual(remaining, [old.hash])
    }

    func testRaisingOrRemovingTheLimitEvictsNothing() async throws {
        _ = try await store.insert(Fixtures.imageCapture(width: 32, height: 32), at: date(1))
        _ = try await store.insert(Fixtures.imageCapture(width: 40, height: 40), at: date(2))
        let used = try await store.storageUsage()
        var removed = try await store.setStorageBudget(used * 10)
        XCTAssertEqual(removed, 0)
        removed = try await store.setStorageBudget(nil)
        XCTAssertEqual(removed, 0)
        let count = try await store.count()
        XCTAssertEqual(count, 2)
    }

    func testEvictionRunsInBatches() async throws {
        let rows = Constants.Storage.evictionBatch + 5
        for offset in 0..<rows {
            _ = try await store.insert(Fixtures.textCapture("row \(offset) padding padding"), at: date(TimeInterval(offset)))
        }
        let removed = try await store.setStorageBudget(1)
        XCTAssertEqual(removed, rows - 1)
        let remaining = try await store.page().map(\.title)
        XCTAssertEqual(remaining, ["row \(rows - 1) padding padding"])
    }

    func testSessionFlagReportsAnUncleanPreviousSession() async throws {
        let firstLaunch = try await store.beginSession()
        XCTAssertFalse(firstLaunch, "a new database has never been closed cleanly")
        store.markCleanShutdown()
        let afterCleanQuit = try await store.beginSession()
        XCTAssertTrue(afterCleanQuit)
        let afterCrash = try await store.beginSession()
        XCTAssertFalse(afterCrash, "beginSession clears the flag, so a kill before the next clean quit reads as unclean")
    }

    func testGarbageCollectionRecountsBytesAndRecordsUnrecordedThumbnails() async throws {
        let image = Fixtures.imageCapture(width: 16, height: 16)
        _ = try await store.insert(image)
        // A manually written thumbnail represents a thumbnail saved just before a crash recorded
        // the thumbnail's size.
        let png = Fixtures.png(width: 4, height: 4)
        try png.write(to: store.location.thumbnailURL(for: image.hash))
        let tamper = try Database(path: store.location.database.path)
        try tamper.run("UPDATE stats SET total_bytes = 999999 WHERE id = 1")

        _ = try await store.collectGarbage()

        let used = try await store.storageUsage()
        XCTAssertEqual(used, blobSize(image) + Int64(png.count))
    }

    // MARK: - Schema

    func testMigrationFromEmptyDatabase() async throws {
        let fresh = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fresh) }
        let location = StoreLocation(root: fresh)
        do {
            let empty = try Database(path: location.database.path)
            XCTAssertEqual(try empty.userVersion(), 0)
        }

        let migrated = try ClipStore(location: location)
        let version = try await migrated.schemaVersionOnDisk()
        XCTAssertEqual(version, ClipStore.schemaVersion)

        let check = try Database(path: location.database.path)
        let tables = try check.query("SELECT name FROM sqlite_master WHERE type IN ('table', 'index') ORDER BY name") {
            $0.string(0) ?? ""
        }
        for name in ["items", "representations", "files", "items_fts", "items_recent", "stats"] {
            XCTAssertTrue(tables.contains(name), "missing \(name)")
        }
        let journal = try check.query("PRAGMA journal_mode") { $0.string(0) ?? "" }.first
        XCTAssertEqual(journal, "wal")
    }

    func testReopeningKeepsData() async throws {
        _ = try await store.insert(Fixtures.textCapture("persisted"))
        store = nil
        let reopened = try ClipStore(location: StoreLocation(root: directory))
        let titles = try await reopened.page().map(\.title)
        XCTAssertEqual(titles, ["persisted"])
    }

    func testMigrationFromVersionOneKeepsRows() async throws {
        let fresh = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fresh) }
        let location = StoreLocation(root: fresh)
        do {
            let old = try Database(path: location.database.path)
            try ClipStore.configure(old)
            try ClipStore.migrate(old, upTo: 1)
            try old.run(
                """
                INSERT INTO items (hash, kind, created_at, last_used, title, search_text, byte_size, blob_type, file_count)
                VALUES ('h1', 1, 1, 1, 'old image', 'old image', 3, 'public.png', 0)
                """
            )
            XCTAssertEqual(try old.userVersion(), 1)
        }
        try FileManager.default.createDirectory(at: location.blobs, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: location.blobURL(for: "h1"))

        let migrated = try ClipStore(location: location)
        let version = try await migrated.schemaVersionOnDisk()
        XCTAssertEqual(version, ClipStore.schemaVersion)
        let page = try await migrated.page()
        XCTAssertEqual(page.map(\.title), ["old image"])
        let payload = try await migrated.payload(for: page[0].id)
        XCTAssertEqual(payload?.blob?.data, Data([1, 2, 3]))
        XCTAssertEqual(payload?.representations, [])
    }

    func testMigrationFromVersionTwoKeepsPlainTextForOldRows() async throws {
        let fresh = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fresh) }
        let location = StoreLocation(root: fresh)
        do {
            let old = try Database(path: location.database.path)
            try ClipStore.configure(old)
            try ClipStore.migrate(old, upTo: 2)
            try old.run(
                """
                INSERT INTO items (hash, kind, created_at, last_used, title, search_text, byte_size, file_count, offers_tiff)
                VALUES ('t1', 0, 1, 1, 'old text', 'old text', 8, 0, 0)
                """
            )
            XCTAssertEqual(try old.userVersion(), 2)
        }

        let migrated = try ClipStore(location: location)
        let version = try await migrated.schemaVersionOnDisk()
        XCTAssertEqual(version, ClipStore.schemaVersion)
        let page = try await migrated.page()
        let payload = try await migrated.payload(for: page[0].id)
        XCTAssertEqual(payload?.plainText, "old text")
    }

    func testMigrationFromVersionThreeCountsExistingBytesAndThumbnails() async throws {
        let fresh = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fresh) }
        let location = StoreLocation(root: fresh)
        try FileManager.default.createDirectory(at: location.thumbs, withIntermediateDirectories: true)
        let thumb = Fixtures.png(width: 4, height: 4)
        try thumb.write(to: location.thumbnailURL(for: "img"))
        do {
            let old = try Database(path: location.database.path)
            try ClipStore.configure(old)
            try ClipStore.migrate(old, upTo: 3)
            try old.run(
                """
                INSERT INTO items (hash, kind, created_at, last_used, title, search_text, byte_size, blob_type, file_count)
                VALUES ('txt', 0, 1, 1, 'text', 'text', 100, NULL, 0),
                       ('img', 1, 2, 2, 'image', 'image', 2000, 'public.png', 0),
                       ('vid', 2, 3, 3, 'clip.mov', 'clip.mov', 30000, NULL, 1)
                """
            )
        }

        let migrated = try ClipStore(location: location)
        let version = try await migrated.schemaVersionOnDisk()
        XCTAssertEqual(version, ClipStore.schemaVersion)
        let used = try await migrated.storageUsage()
        XCTAssertEqual(used, 100 + 2000 + Int64(thumb.count), "text and image bytes plus the one thumbnail; the referenced file adds nothing")
        let wasClean = try await migrated.beginSession()
        XCTAssertFalse(wasClean)
    }

    // MARK: - Query plans

    private func plan(_ sql: String, _ values: [SQLValue]) throws -> String {
        let db = try Database(path: store.location.database.path)
        return try db.query("EXPLAIN QUERY PLAN \(sql)", values) { $0.string(3) ?? "" }.joined(separator: " | ")
    }

    func testPagingUsesTheRecentIndex() throws {
        let first = try plan(ClipStore.pageSQL, [.int(100)])
        XCTAssertTrue(first.contains("items_recent"), first)
        XCTAssertFalse(first.contains("TEMP B-TREE"), first)
        let next = try plan(ClipStore.pageAfterSQL, [.double(1), .int(1), .int(100)])
        XCTAssertTrue(next.contains("items_recent"), next)
        XCTAssertFalse(next.contains("TEMP B-TREE"), next)
    }

    func testDedupUsesTheHashIndex() throws {
        let detail = try plan(ClipStore.bumpSQL, [.double(1), .text("h")])
        XCTAssertTrue(detail.contains("USING INDEX sqlite_autoindex_items"), detail)
        XCTAssertTrue(detail.contains("hash=?"), detail)
    }

    func testEvictionScansTheRecentIndexOldestFirst() throws {
        let plan = try plan(ClipStore.oldestSQL, [.int(10)])
        XCTAssertTrue(plan.contains("items_recent"), plan)
        XCTAssertFalse(plan.contains("TEMP B-TREE"), plan)
        let newest = try self.plan(ClipStore.newestSQL, [])
        XCTAssertTrue(newest.contains("items_recent"), newest)
        XCTAssertFalse(newest.contains("TEMP B-TREE"), newest)
    }

    func testSearchUsesTheFullTextIndex() throws {
        let detail = try plan(ClipStore.searchSQL, [.text("\"abc\"*"), .double(.infinity), .int(.max), .int(100)])
        XCTAssertTrue(detail.contains("items_fts VIRTUAL TABLE INDEX"), detail)
        XCTAssertFalse(detail.contains("SCAN items "), detail)
    }

    // MARK: - Volumes

    func testRemoteVolumePathsAreNeverReportedMissing() {
        let volumes = LocalVolumes(remoteMountPoints: ["/Volumes/share"])
        XCTAssertTrue(volumes.isRemote("/Volumes/share/a.mov"))
        XCTAssertTrue(volumes.isRemote("/Volumes/share"))
        XCTAssertFalse(volumes.isRemote("/Volumes/shared/a.mov"))
        XCTAssertFalse(volumes.isMissing(atPath: "/Volumes/share/\(UUID().uuidString)"))
        XCTAssertTrue(volumes.isMissing(atPath: "/nonexistent/\(UUID().uuidString)"))
    }

    func testRootIsNeverTreatedAsRemote() {
        let volumes = LocalVolumes(remoteMountPoints: ["/"])
        XCTAssertFalse(volumes.isRemote("/tmp/a"))
    }

    func testNewerSchemaIsRefused() throws {
        let fresh = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fresh) }
        let location = StoreLocation(root: fresh)
        do {
            let db = try Database(path: location.database.path)
            try db.setUserVersion(ClipStore.schemaVersion + 1)
        }
        XCTAssertThrowsError(try ClipStore(location: location)) { error in
            XCTAssertEqual(error as? StoreError, .newerSchema(ClipStore.schemaVersion + 1))
        }
    }
}

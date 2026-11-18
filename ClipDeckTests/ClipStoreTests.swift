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

    // MARK: - Copy order

    private func everyID() async throws -> [Int64] {
        try await store.page(limit: 10_000).map(\.id)
    }

    func testCopiesAtTheSameInstantListInCopyOrder() async throws {
        let first = try await store.insert(Fixtures.textCapture("needle one"), at: date(1))
        let second = try await store.insert(Fixtures.textCapture("needle two"), at: date(1))
        var listed = try await everyID()
        XCTAssertEqual(listed, [second.id, first.id])

        try await store.touch(id: second.id, at: date(5))
        try await store.touch(id: first.id, at: date(5))
        listed = try await everyID()
        XCTAssertEqual(listed, [first.id, second.id], "the copy made last is listed first")
        let found = try await store.search("needle").map(\.id)
        XCTAssertEqual(found, listed)
    }

    func testACopyMadeAfterTheClockSteppedBackIsListedFirst() async throws {
        let early = try await store.insert(Fixtures.textCapture("needle early"), at: date(50))
        let late = try await store.insert(Fixtures.textCapture("needle late"), at: date(10))
        var listed = try await store.page()
        XCTAssertEqual(listed.map(\.id), [late.id, early.id])
        XCTAssertGreaterThan(try XCTUnwrap(listed.first).lastUsed, date(50))
        XCTAssertLessThan(try XCTUnwrap(listed.first).lastUsed, date(50.001))
        var found = try await store.search("needle").map(\.id)
        XCTAssertEqual(found, listed.map(\.id))

        try await store.touch(id: early.id, at: date(20))
        _ = try await store.insert(Fixtures.textCapture("needle late"), at: date(5))
        listed = try await store.page()
        XCTAssertEqual(listed.map(\.id), [late.id, early.id])
        found = try await store.search("needle").map(\.id)
        XCTAssertEqual(found, listed.map(\.id))

        // The list pages the same way the search does.
        let rest = try await store.page(after: PageCursor(after: listed[0]), limit: 5).map(\.id)
        XCTAssertEqual(rest, [early.id])
        let restFound = try await store.search("needle", after: PageCursor(after: listed[0]), limit: 5).map(\.id)
        XCTAssertEqual(restFound, [early.id])
    }

    func testTheLatestCopySurvivesEvictionAfterTheClockSteppedBack() async throws {
        let old = Fixtures.imageCapture(width: 40, height: 40)
        let latest = Fixtures.imageCapture(width: 44, height: 44)
        _ = try await store.insert(old, at: date(50))
        _ = try await store.insert(latest, at: date(10))
        _ = try await store.setStorageBudget(blobSize(latest) + 1)
        let remaining = try await store.page().map(\.hash)
        XCTAssertEqual(remaining, [latest.hash])
    }

    func testCopyingTheNewestRowAgainKeepsItsPlaceInTheIndex() async throws {
        _ = try await store.insert(Fixtures.textCapture("needle one"), at: date(1))
        let newest = try await store.insert(Fixtures.textCapture("needle two"), at: date(2))
        let db = try Database(path: store.location.database.path)
        let before = try db.scalarInt("SELECT seq FROM items WHERE id = ?", [.int(newest.id)])
        try await store.touch(id: newest.id, at: date(3))
        _ = try await store.insert(Fixtures.textCapture("needle two"), at: date(1))
        XCTAssertEqual(try db.scalarInt("SELECT seq FROM items WHERE id = ?", [.int(newest.id)]), before)
        let listed = try await store.page()
        XCTAssertEqual(listed.first?.id, newest.id)
        XCTAssertGreaterThan(try XCTUnwrap(listed.first).lastUsed, date(3))
    }

    func testTouchingAMissingRowChangesNothing() async throws {
        let only = try await store.insert(Fixtures.textCapture("only"), at: date(1))
        try await store.touch(id: only.id + 100, at: date(9))
        let listed = try await store.page()
        XCTAssertEqual(listed.map(\.lastUsed), [date(1)])
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

    func testSearchMatchesPrefixesOfEveryLength() async throws {
        _ = try await store.insert(Fixtures.textCapture("Caf\u{E9} connection"), at: date(1))
        _ = try await store.insert(Fixtures.textCapture("configuration"), at: date(2))
        _ = try await store.insert(Fixtures.textCapture("cobalt"), at: date(3))

        for (query, expected) in [
            ("c", ["cobalt", "configuration", "Caf\u{E9} connection"]),
            ("co", ["cobalt", "configuration", "Caf\u{E9} connection"]),
            ("con", ["configuration", "Caf\u{E9} connection"]),
            ("conf", ["configuration"]),
            ("ca", ["Caf\u{E9} connection"]),
            ("caf", ["Caf\u{E9} connection"]),
            ("cafe conn", ["Caf\u{E9} connection"]),
            ("cx", []),
        ] {
            let titles = try await store.search(query).map(\.title)
            XCTAssertEqual(titles, expected, query)
        }
    }

    func testSearchListsARepeatCopyFirst() async throws {
        let first = try await store.insert(Fixtures.textCapture("needle one"), at: date(1))
        _ = try await store.insert(Fixtures.textCapture("needle two"), at: date(2))
        let third = try await store.insert(Fixtures.textCapture("needle three"), at: date(3))

        _ = try await store.insert(Fixtures.textCapture("needle one"), at: date(4))
        var titles = try await store.search("needle").map(\.title)
        XCTAssertEqual(titles, ["needle one", "needle three", "needle two"])

        try await store.touch(id: third.id, at: date(5))
        titles = try await store.search("needle").map(\.title)
        XCTAssertEqual(titles, ["needle three", "needle one", "needle two"])

        // Copying the newest item again does not change the order, and the search returns the item
        // once.
        try await store.touch(id: third.id, at: date(6))
        _ = try await store.insert(Fixtures.textCapture("needle three"), at: date(7))
        let results = try await store.search("needle")
        XCTAssertEqual(results.map(\.title), ["needle three", "needle one", "needle two"])
        XCTAssertEqual(results.first?.lastUsed, date(7))
        XCTAssertEqual(results.last?.id, first.id + 1)
    }

    func testSearchOrderMatchesTheListOrder() async throws {
        for index in 0..<40 {
            _ = try await store.insert(Fixtures.textCapture("needle \(index)"), at: date(TimeInterval(index)))
        }
        for index in stride(from: 0, to: 40, by: 3) {
            _ = try await store.insert(Fixtures.textCapture("needle \(index)"), at: date(TimeInterval(100 + index)))
        }
        let listed = try await store.page().map(\.id)
        let found = try await store.search("needle").map(\.id)
        XCTAssertEqual(found, listed)
    }

    func testSearchPagesInCopyOrderWhenTheClockStepsBack() async throws {
        _ = try await store.insert(Fixtures.textCapture("needle early clock"), at: date(50))
        _ = try await store.insert(Fixtures.textCapture("needle late clock"), at: date(10))

        let first = try await store.search("needle", limit: 1)
        XCTAssertEqual(first.map(\.title), ["needle late clock"], "the copy made last comes first")
        let second = try await store.search("needle", after: PageCursor(after: try XCTUnwrap(first.first)), limit: 1)
        XCTAssertEqual(second.map(\.title), ["needle early clock"])
        let third = try await store.search("needle", after: PageCursor(after: try XCTUnwrap(second.first)), limit: 1)
        XCTAssertTrue(third.isEmpty)
    }

    func testSearchPagingSurvivesACursorRowThatMoved() async throws {
        for index in 0..<30 {
            _ = try await store.insert(Fixtures.textCapture("needle \(index)"), at: date(TimeInterval(index)))
        }
        let first = try await store.search("needle", limit: 10)
        let last = try XCTUnwrap(first.last)
        XCTAssertEqual(last.title, "needle 20")

        // The row named by the cursor is copied again, so the cursor no longer marks the row's old
        // position.
        try await store.touch(id: last.id, at: date(100))
        let second = try await store.search("needle", after: PageCursor(after: last), limit: 100)
        XCTAssertEqual(second.map(\.title), (0..<20).reversed().map { "needle \($0)" })

        // The row the cursor names is gone.
        try await store.clear(ClearRequest(range: .allTime, kinds: [.text], now: date(200)))
        let afterClear = try await store.search("needle", after: PageCursor(after: last), limit: 100)
        XCTAssertTrue(afterClear.isEmpty)
    }

    func testSearchPagingCoversEveryRowOnceWhileRowsMoveAndLeave() async throws {
        for index in 0..<60 {
            // The copies arrive in groups of three. All copies in each group receive the same time.
            _ = try await store.insert(Fixtures.textCapture("needle \(index)"), at: date(TimeInterval(index - index % 3)))
        }
        let before = try await store.search("needle", limit: 1_000).map(\.id)
        XCTAssertEqual(before.count, 60)

        var seen: [Int64] = []
        var cursor: PageCursor?
        var step = 0
        var moved: Set<Int64> = []
        var removed: Set<Int64> = []
        while true {
            let page = try await store.search("needle", after: cursor, limit: 7)
            guard let last = page.last else { break }
            seen += page.map(\.id)
            cursor = PageCursor(after: last)
            // Between pages the cursor row is copied again, then removed, then left alone.
            switch step % 3 {
            case 0:
                try await store.touch(id: last.id, at: date(1_000 + TimeInterval(step)))
                moved.insert(last.id)
            case 1:
                let db = try Database(path: store.location.database.path)
                try db.run(ClipStore.evictSQL, [.text("[\(last.id)]")])
                removed.insert(last.id)
            default:
                break
            }
            step += 1
            XCTAssertLessThan(step, 100, "the paging does not end")
        }
        XCTAssertEqual(seen.count, Set(seen).count, "a row came back twice")
        XCTAssertEqual(seen, before, "rows that moved or left were already shown; the rest follow in order")
        XCTAssertFalse(moved.isEmpty)
        XCTAssertFalse(removed.isEmpty)
    }

    func testListPagingCoversEveryRowOnceWhileRowsMoveAndLeave() async throws {
        for index in 0..<60 {
            _ = try await store.insert(Fixtures.textCapture("row \(index)"), at: date(TimeInterval(index - index % 3)))
        }
        let before = try await store.page(limit: 1_000).map(\.id)
        var seen: [Int64] = []
        var cursor: PageCursor?
        var step = 0
        while true {
            let page = try await store.page(after: cursor, limit: 7)
            guard let last = page.last else { break }
            seen += page.map(\.id)
            cursor = PageCursor(after: last)
            if step % 2 == 0 {
                try await store.touch(id: last.id, at: date(1_000 + TimeInterval(step)))
            } else {
                let db = try Database(path: store.location.database.path)
                try db.run(ClipStore.evictSQL, [.text("[\(last.id)]")])
            }
            step += 1
            XCTAssertLessThan(step, 100, "the paging does not end")
        }
        XCTAssertEqual(seen, before)
    }

    func testSearchHandlesWordsOfEveryShape() async throws {
        let titles = [
            "x marks the spot", "\u{65E5}\u{672C}\u{8A9E} \u{30C6}\u{30AD}\u{30B9}\u{30C8}", "party \u{1F389} time",
            "say \"cheese\" AND smile", "NEAR(a b) search_text : col", "C++ and c# -flag ^caret", "\u{24B6} circled",
            "na\u{EF}ve r\u{E9}sum\u{E9}", "under_score-dash.dot",
        ]
        for (offset, title) in titles.enumerated() {
            _ = try await store.insert(Fixtures.textCapture(title), at: date(TimeInterval(offset)))
        }
        for (query, expected) in [
            ("x", ["x marks the spot"]),
            ("\u{65E5}", ["\u{65E5}\u{672C}\u{8A9E} \u{30C6}\u{30AD}\u{30B9}\u{30C8}"]),
            ("\u{65E5}\u{672C} \u{30C6}\u{30AD}", ["\u{65E5}\u{672C}\u{8A9E} \u{30C6}\u{30AD}\u{30B9}\u{30C8}"]),
            ("\u{1F389}", []),
            ("party \u{1F389}", ["party \u{1F389} time"]),
            ("\"cheese\"", ["say \"cheese\" AND smile"]),
            ("\"", []),
            ("AND", ["C++ and c# -flag ^caret", "say \"cheese\" AND smile"]),
            ("OR NOT", []),
            ("NEAR(a", ["NEAR(a b) search_text : col"]),
            ("search_text : col", ["NEAR(a b) search_text : col"]),
            ("c++", ["\u{24B6} circled", "C++ and c# -flag ^caret", "NEAR(a b) search_text : col", "say \"cheese\" AND smile"]),
            ("-flag", ["C++ and c# -flag ^caret"]),
            ("^caret *", ["C++ and c# -flag ^caret"]),
            ("circled \u{24B6}", ["\u{24B6} circled"]),
            ("naive resume", ["na\u{EF}ve r\u{E9}sum\u{E9}"]),
            ("under_score-dash.d", ["under_score-dash.dot"]),
            ("... ---", []),
            ("spot\u{0}marks", ["x marks the spot"]),
            ("\u{0}", []),
        ] {
            let found = try await store.search(query).map(\.title)
            XCTAssertEqual(found, expected, query.debugDescription)
        }
    }

    func testANewItemAfterTheNewestWasClearedIsFoundAlone() async throws {
        _ = try await store.insert(Fixtures.textCapture("kept entry"), at: date(-10_000))
        _ = try await store.insert(Fixtures.textCapture("doomed entry"), at: date(2))
        try await store.clear(ClearRequest(range: .lastHour, kinds: [.text], now: date(2)))
        _ = try await store.insert(Fixtures.textCapture("fresh entry"), at: date(3))

        let doomed = try await store.search("doomed")
        XCTAssertTrue(doomed.isEmpty)
        let entries = try await store.search("entry").map(\.title)
        XCTAssertEqual(entries, ["fresh entry", "kept entry"])
    }

    func testEvictedItemsLeaveSearchIndex() async throws {
        _ = try await store.insert(Fixtures.textCapture("searchable old padding padding"), at: date(1))
        let newest = Fixtures.textCapture("searchable new")
        _ = try await store.insert(newest, at: date(2))
        let removed = try await store.setStorageBudget(newest.byteSize)
        XCTAssertEqual(removed, 1)
        let titles = try await store.search("searchable").map(\.title)
        XCTAssertEqual(titles, ["searchable new"])
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

    func testTextWithANulCharacterKeepsItsTail() async throws {
        let text = "before\u{0}after"
        let id = try await store.insert(Fixtures.textCapture(text)).id
        let payload = try await store.payload(for: id)
        XCTAssertEqual(payload?.plainText, text)
        let found = try await store.search("after")
        XCTAssertEqual(found.map(\.id), [id])
    }

    func testRowPreviewHoldsTheStartOfALongText() async throws {
        let long = String(repeating: "\u{1F4CE}\u{E9}x", count: 400)
        let short = String(repeating: "y", count: Constants.List.rowPreviewCharacters)
        _ = try await store.insert(Fixtures.textCapture(long), at: date(1))
        _ = try await store.insert(Fixtures.textCapture(short), at: date(2))

        let page = try await store.page()
        XCTAssertEqual(page.map(\.preview), [short, String(String.UnicodeScalarView(long.unicodeScalars.prefix(300)))])
        let found = try await store.search("yyy")
        XCTAssertEqual(found.map(\.preview), [short])
    }

    func testRowPreviewStaysShortWhenALongTextHoldsANul() async throws {
        let long = "ab\u{0}" + String(repeating: "tail ", count: 20_000)
        let short = "cd\u{0}tail"
        _ = try await store.insert(Fixtures.textCapture(long), at: date(1))
        _ = try await store.insert(Fixtures.textCapture(short), at: date(2))

        let page = try await store.page()
        XCTAssertEqual(page.map(\.preview), [short, "ab"], "the stored start of a text ends at a NUL, the way the list read it before")
        let db = try Database(path: store.location.database.path)
        let stored = try db.query("SELECT preview IS NULL FROM items ORDER BY id") { $0.int64(0) }
        XCTAssertEqual(stored, [0, 1])
        let found = try await store.search("tail").map(\.preview)
        XCTAssertEqual(found, [short, "ab"])
    }

    func testTextPreviewCutsBetweenCharacters() async throws {
        let wide = String(repeating: "\u{1F4CE}", count: 9) + "\u{E9}\u{1F4CE}\u{1F4CE}"
        let wideID = try await store.insert(Fixtures.textCapture(wide)).id
        for count in 0...13 {
            let preview = try await store.textPreview(for: wideID, maxCharacters: count)
            XCTAssertEqual(preview, String(String.UnicodeScalarView(wide.unicodeScalars.prefix(count))), "\(count)")
        }
        let negative = try await store.textPreview(for: wideID, maxCharacters: -4)
        XCTAssertEqual(negative, "")

        let nul = try await store.insert(Fixtures.textCapture("one\u{0}two")).id
        let whole = try await store.textPreview(for: nul)
        XCTAssertEqual(whole, "one\u{0}two")

        try await store.clear(ClearRequest(range: .allTime, kinds: [.text]))
        let gone = try await store.textPreview(for: wideID)
        XCTAssertEqual(gone, "")
    }

    func testTextPreviewReadsTheStartOfTheText() async throws {
        let long = String(repeating: "\u{1F4CE}\u{E9}x", count: 5_000)
        let longID = try await store.insert(Fixtures.textCapture(long)).id
        let shortID = try await store.insert(Fixtures.textCapture("short text")).id

        let preview = try await store.textPreview(for: longID)
        XCTAssertEqual(preview, String(String.UnicodeScalarView(long.unicodeScalars.prefix(Constants.List.detailPreviewCharacters))))
        let few = try await store.textPreview(for: longID, maxCharacters: 2)
        XCTAssertEqual(few, "\u{1F4CE}\u{E9}")
        let whole = try await store.textPreview(for: shortID)
        XCTAssertEqual(whole, "short text")
        let none = try await store.textPreview(for: shortID, maxCharacters: 0)
        XCTAssertEqual(none, "")
        let missing = try await store.textPreview(for: 9_999)
        XCTAssertEqual(missing, "")
    }

    func testRepeatCopyWithFormatsOfTheSameLengthReplacesThem() async throws {
        let first = try await store.insert(Fixtures.textCapture("baz", rtf: Data("{\\rtf1 red}".utf8)), at: date(1))
        let again = try await store.insert(Fixtures.textCapture("baz", rtf: Data("{\\rtf1 tan}".utf8)), at: date(2))
        XCTAssertEqual(again, .bumped(first.id))
        var payload = try await store.payload(for: first.id)
        XCTAssertEqual(payload?.representations.map(\.data), [Data("{\\rtf1 tan}".utf8)])

        // When the formats are the same, the stored formats stay in place.
        _ = try await store.insert(Fixtures.textCapture("baz", rtf: Data("{\\rtf1 tan}".utf8)), at: date(3))
        payload = try await store.payload(for: first.id)
        XCTAssertEqual(payload?.representations, [PasteboardRepresentation(type: PasteboardTypes.rtf, data: Data("{\\rtf1 tan}".utf8))])
        let page = try await store.page()
        XCTAssertEqual(page.first?.lastUsed, date(3))
    }

    func testRepeatCopyOfFilesKeepsOrReplacesTheReferences() async throws {
        let paths = ["/tmp/a.txt", "/tmp/b.txt"]
        let first = try await store.insert(Fixtures.fileCapture(paths), at: date(1))
        _ = try await store.insert(Fixtures.fileCapture(paths), at: date(2))
        var payload = try await store.payload(for: first.id)
        XCTAssertEqual(payload?.files.map(\.path), paths)

        // The same files in another order share the hash, and the new order is stored.
        let again = try await store.insert(Fixtures.fileCapture(paths.reversed()), at: date(3))
        XCTAssertEqual(again, .bumped(first.id))
        payload = try await store.payload(for: first.id)
        XCTAssertEqual(payload?.files.map(\.path), paths.reversed())
        XCTAssertEqual(payload?.files.first?.bookmark, Data("bookmark:/tmp/b.txt".utf8))
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

    private func stagedFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: store.location.staging.path)) ?? []
    }

    func testBlobAndThumbnailLeaveNothingInStaging() async throws {
        let image = Fixtures.imageCapture()
        _ = try await store.insert(image)
        try await store.saveThumbnail(Fixtures.png(width: 2, height: 2), for: image.hash)
        _ = try await store.insert(image)
        XCTAssertEqual(stagedFiles(), [])
        XCTAssertEqual(try Data(contentsOf: store.location.blobURL(for: image.hash)), image.blob?.data)
        XCTAssertEqual(try Data(contentsOf: store.location.thumbnailURL(for: image.hash)), Fixtures.png(width: 2, height: 2))
    }

    func testRepeatCopyRestoresABlobThatWentMissing() async throws {
        let image = Fixtures.imageCapture()
        let first = try await store.insert(image, at: date(1))
        try FileManager.default.removeItem(at: store.location.blobURL(for: image.hash))

        let again = try await store.insert(image, at: date(2))
        XCTAssertEqual(again, .bumped(first.id))
        let payload = try await store.payload(for: first.id)
        XCTAssertEqual(payload?.blob, image.blob)
    }

    func testAFailedInsertLeavesNoBlobBehind() async throws {
        let image = Fixtures.imageCapture()
        let blocker = try Database(path: store.location.database.path)
        try blocker.execute("BEGIN IMMEDIATE")
        do {
            _ = try await store.insert(image)
            XCTFail("the insert should fail while another connection holds the write lock")
        } catch {}
        try blocker.execute("ROLLBACK")

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location.blobURL(for: image.hash).path))
        XCTAssertEqual(stagedFiles(), [])
        let count = try await store.count()
        XCTAssertEqual(count, 0)
    }

    func testAFailedRepeatCopyKeepsTheBlobOfTheStoredRow() async throws {
        let image = Fixtures.imageCapture()
        _ = try await store.insert(image, at: date(1))
        let blocker = try Database(path: store.location.database.path)
        try blocker.execute("BEGIN IMMEDIATE")
        do {
            _ = try await store.insert(image, at: date(2))
            XCTFail("the insert should fail while another connection holds the write lock")
        } catch {}
        try blocker.execute("ROLLBACK")

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.location.blobURL(for: image.hash).path))
    }

    func testAnInsertThatFailsPartWayLeavesNoRowAndNoIndexEntry() async throws {
        let first = try await store.insert(Fixtures.textCapture("needle kept", rtf: Data("{\\rtf1 a}".utf8)), at: date(1))
        _ = try await store.insert(Fixtures.textCapture("needle newer"), at: date(2))
        guard case .capture(let image) = Fixtures.classifier().classify(Fixtures.snapshot([[
            PasteboardTypes.png: Fixtures.png(width: 9, height: 9), PasteboardTypes.html: Data("<img>".utf8),
        ]])) else { return XCTFail("image did not classify") }
        do {
            // The row is inserted, but its formats are rejected, so the transaction rolls back.
            let db = try Database(path: store.location.database.path)
            try db.execute("CREATE TRIGGER refuse_formats BEFORE INSERT ON representations BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
        for capture in [Fixtures.textCapture("needle lost", rtf: Data("{\\rtf1 b}".utf8)), image] {
            do {
                _ = try await store.insert(capture, at: date(3))
                XCTFail("the insert should fail")
            } catch {}
        }
        // When a repeat copy with other formats moves the row and then fails, ClipDeck undoes the
        // move.
        do {
            _ = try await store.insert(Fixtures.textCapture("needle kept", rtf: Data("{\\rtf1 changed}".utf8)), at: date(4))
            XCTFail("the repeat copy should fail")
        } catch {}

        var found = try await store.search("needle").map(\.title)
        XCTAssertEqual(found, ["needle newer", "needle kept"])
        let listed = try await store.page()
        XCTAssertEqual(listed.map(\.title), ["needle newer", "needle kept"])
        XCTAssertEqual(listed.map(\.lastUsed), [date(2), date(1)])
        let payload = try await store.payload(for: first.id)
        XCTAssertEqual(payload?.representations.map(\.data), [Data("{\\rtf1 a}".utf8)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location.blobURL(for: image.hash).path))
        XCTAssertEqual(stagedFiles(), [])
        try StoreInspector.assertSound(at: store.location)

        do {
            let db = try Database(path: store.location.database.path)
            try db.execute("DROP TRIGGER refuse_formats")
        }
        _ = try await store.insert(Fixtures.textCapture("needle lost", rtf: Data("{\\rtf1 b}".utf8)), at: date(5))
        _ = try await store.insert(image, at: date(6))
        found = try await store.search("needle").map(\.title)
        XCTAssertEqual(found, ["needle lost", "needle newer", "needle kept"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.location.blobURL(for: image.hash).path))
        try StoreInspector.assertSound(at: store.location)
    }

    func testImagesAreStoredAfterTheEmptyDirectoriesWereRemoved() async throws {
        let location = store.location
        for directory in [location.staging, location.blobs, location.thumbs] {
            try FileManager.default.removeItem(at: directory)
        }
        let image = Fixtures.imageCapture(width: 21, height: 21)
        let id = try await store.insert(image, at: date(1)).id
        let saved = try await store.saveThumbnail(Fixtures.png(width: 2, height: 2), for: image.hash)
        XCTAssertTrue(saved)
        let payload = try await store.payload(for: id)
        XCTAssertEqual(payload?.blob, image.blob)
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.thumbnailURL(for: image.hash).path))
        XCTAssertEqual(stagedFiles(), [])

        // A repeat copy writes an image's file again if the file was removed with its directory.
        try FileManager.default.removeItem(at: location.blobs)
        try FileManager.default.removeItem(at: location.staging)
        _ = try await store.insert(image, at: date(2))
        XCTAssertEqual(try Data(contentsOf: location.blobURL(for: image.hash)), image.blob?.data)
    }

    func testOpeningTheStoreEmptiesStaging() async throws {
        let leftover = store.location.staging.appendingPathComponent("interrupted")
        try Data([1, 2, 3]).write(to: leftover)
        store = nil
        store = try ClipStore(location: StoreLocation(root: directory))
        XCTAssertEqual(stagedFiles(), [])
    }

    func testThumbnailForDeletedRowIsNotSaved() async throws {
        let image = Fixtures.imageCapture()
        _ = try await store.insert(image)
        try await store.clear(ClearRequest(range: .allTime, kinds: [.image]))
        let saved = try await store.saveThumbnail(Fixtures.png(width: 2, height: 2), for: image.hash)
        XCTAssertFalse(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location.thumbnailURL(for: image.hash).path))
        XCTAssertEqual(stagedFiles(), [])
    }

    func testAFailedThumbnailSaveLeavesNoFile() async throws {
        let image = Fixtures.imageCapture()
        _ = try await store.insert(image)
        let blocker = try Database(path: store.location.database.path)
        try blocker.execute("BEGIN IMMEDIATE")
        do {
            _ = try await store.saveThumbnail(Fixtures.png(width: 2, height: 2), for: image.hash)
            XCTFail("the save should fail while another connection holds the write lock")
        } catch {}
        try blocker.execute("ROLLBACK")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location.thumbnailURL(for: image.hash).path))
        XCTAssertEqual(stagedFiles(), [])
    }

    func testAFailedThumbnailSaveKeepsTheThumbnailTheRowRecords() async throws {
        let image = Fixtures.imageCapture()
        _ = try await store.insert(image)
        let recorded = Fixtures.png(width: 2, height: 2)
        try await store.saveThumbnail(recorded, for: image.hash)
        let blocker = try Database(path: store.location.database.path)
        try blocker.execute("BEGIN IMMEDIATE")
        do {
            _ = try await store.saveThumbnail(Fixtures.png(width: 3, height: 3), for: image.hash)
            XCTFail("the save should fail while another connection holds the write lock")
        } catch {}
        try blocker.execute("ROLLBACK")
        XCTAssertEqual(try Data(contentsOf: store.location.thumbnailURL(for: image.hash)), recorded)
        XCTAssertEqual(stagedFiles(), [])
        let used = try await store.storageUsage()
        XCTAssertEqual(used, blobSize(image) + Int64(recorded.count))
    }

    func testRemovingARowRemovesAThumbnailItNeverRecorded() async throws {
        let image = Fixtures.imageCapture(width: 5, height: 5)
        let file = Fixtures.fileCapture(["/tmp/unrecorded.mov"])
        _ = try await store.insert(image, at: date(1))
        _ = try await store.insert(file, at: date(2))
        // An earlier version could leave a thumbnail on disk with no size in the row.
        for hash in [image.hash, file.hash] {
            try Fixtures.png(width: 2, height: 2).write(to: store.location.thumbnailURL(for: hash))
        }
        _ = try await store.insert(Fixtures.textCapture("newest"), at: date(3))

        try await store.clear(ClearRequest(range: .allTime, kinds: [.image]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location.thumbnailURL(for: image.hash).path))
        _ = try await store.setStorageBudget(1)
        let remaining = try await store.page().map(\.title)
        XCTAssertEqual(remaining, ["newest"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location.thumbnailURL(for: file.hash).path))
    }

    func testTwoCapturesOfOneImageAtOnceStoreOneRowAndOneBlob() async throws {
        let image = Fixtures.imageCapture(width: 30, height: 30)
        let store: ClipStore = self.store
        async let first = store.insert(image, at: date(1))
        async let second = store.insert(image, at: date(2))
        let outcomes = try await [first, second]
        XCTAssertEqual(Set(outcomes.map(\.id)).count, 1)
        let count = try await store.count()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try Data(contentsOf: store.location.blobURL(for: image.hash)), image.blob?.data)
        XCTAssertEqual(stagedFiles(), [])
        let used = try await store.storageUsage()
        XCTAssertEqual(used, blobSize(image))
    }

    func testAnImageCopiedWhileItIsEvictedKeepsItsBlob() async throws {
        let image = Fixtures.imageCapture(width: 34, height: 34)
        let other = Fixtures.imageCapture(width: 35, height: 35)
        let store: ClipStore = self.store
        for round in 0..<40 {
            _ = try await store.insert(image, at: date(TimeInterval(round * 10)))
            _ = try await store.insert(other, at: date(TimeInterval(round * 10 + 1)))
            // Evicting the first image and copying it again start at the same time.
            async let evicted = store.setStorageBudget(blobSize(other))
            async let copied = store.insert(image, at: date(TimeInterval(round * 10 + 2)))
            _ = try await (evicted, copied)
            _ = try await store.setStorageBudget(nil)
            let rows = try await store.page()
            for row in rows where row.kind == .image {
                XCTAssertFalse(row.isMissing, "round \(round)")
                let payload = try await store.payload(for: row.id)
                XCTAssertNotNil(payload?.blob, "round \(round)")
            }
            let blobs = try FileManager.default.contentsOfDirectory(atPath: store.location.blobs.path)
            XCTAssertEqual(Set(blobs), Set(rows.map(\.hash)), "round \(round)")
        }
        XCTAssertEqual(stagedFiles(), [])
    }

    func testAThumbnailSavedWhileItsRowLeavesIsNotLeftBehind() async throws {
        let image = Fixtures.imageCapture(width: 36, height: 36)
        let png = Fixtures.png(width: 2, height: 2)
        let store: ClipStore = self.store
        for round in 0..<40 {
            _ = try await store.insert(image, at: date(TimeInterval(round)))
            async let saved = store.saveThumbnail(png, for: image.hash)
            async let cleared = store.clear(ClearRequest(range: .allTime, kinds: [.image]))
            _ = try await (saved, cleared)
            let thumbs = try FileManager.default.contentsOfDirectory(atPath: store.location.thumbs.path)
            XCTAssertEqual(thumbs, [], "round \(round)")
            let used = try await store.storageUsage()
            XCTAssertEqual(used, 0, "round \(round)")
        }
        XCTAssertEqual(stagedFiles(), [])
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

    func testCountMatchesWhatClearRemovesForEveryRequest() async throws {
        let now = date(100_000)
        var kinds: [Set<ClipKind>] = [[]]
        for kind in ClipKind.allCases { kinds += kinds.map { $0.union([kind]) } }
        for range in ClearRange.allCases {
            for kinds in kinds {
                try await store.clear(ClearRequest(range: .allTime, kinds: Set(ClipKind.allCases)))
                var rows: [(ClipKind, Date)] = []
                // The rows are inserted oldest first, so the store keeps every date as given.
                for (offset, age) in [3_000_000.0, 300_000, 30_000, 3_000, 30].enumerated() {
                    let captures = [
                        Fixtures.textCapture("text \(offset)"), Fixtures.imageCapture(width: 4 + offset, height: 3),
                        Fixtures.fileCapture(["/tmp/file \(offset).txt"]),
                    ]
                    for (shift, capture) in captures.enumerated() {
                        let when = now.addingTimeInterval(-age + TimeInterval(shift))
                        _ = try await store.insert(capture, at: when)
                        rows.append((capture.kind, when))
                    }
                }
                let request = ClearRequest(range: range, kinds: kinds, now: now)
                let expected = rows.filter { row in
                    kinds.contains(row.0) && (request.cutoff.map { row.1 >= $0 } ?? true)
                }.count
                let counted = try await store.count(matching: request)
                XCTAssertEqual(counted, expected, "\(range) \(kinds)")
                let removed = try await store.clear(request)
                XCTAssertEqual(removed, expected, "\(range) \(kinds)")
                let left = try await store.count()
                XCTAssertEqual(left, rows.count - expected, "\(range) \(kinds)")
            }
        }
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

    func testClearingTextKeepsTheFilesOfOtherKinds() async throws {
        let image = Fixtures.imageCapture()
        let file = Fixtures.fileCapture(["/tmp/kept.txt"])
        _ = try await store.insert(Fixtures.textCapture("going"), at: date(1))
        _ = try await store.insert(image, at: date(2))
        _ = try await store.insert(file, at: date(3))
        try await store.saveThumbnail(Fixtures.png(width: 2, height: 2), for: file.hash)

        let removed = try await store.clear(ClearRequest(range: .allTime, kinds: [.text]))
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.location.blobURL(for: image.hash).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.location.thumbnailURL(for: file.hash).path))

        let everything = try await store.clear(ClearRequest(range: .allTime, kinds: Set(ClipKind.allCases)))
        XCTAssertEqual(everything, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location.blobURL(for: image.hash).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location.thumbnailURL(for: file.hash).path))
        let used = try await store.storageUsage()
        XCTAssertEqual(used, 0)
    }

    func testClearedItemsLeaveSearchIndex() async throws {
        _ = try await store.insert(Fixtures.textCapture("searchable gone"))
        try await store.clear(ClearRequest(range: .allTime, kinds: [.text]))
        let results = try await store.search("searchable")
        XCTAssertTrue(results.isEmpty)
    }

    func testClearingEverythingEmptiesTheSearchIndex() async throws {
        for index in 0..<20 {
            _ = try await store.insert(Fixtures.textCapture("needle \(index)"), at: date(TimeInterval(index)))
        }
        _ = try await store.insert(Fixtures.fileCapture(["/tmp/needle.txt"]), at: date(30))
        let removed = try await store.clear(ClearRequest(range: .allTime, kinds: Set(ClipKind.allCases)))
        XCTAssertEqual(removed, 21)
        let gone = try await store.search("needle")
        XCTAssertTrue(gone.isEmpty)

        _ = try await store.insert(Fixtures.textCapture("needle again"), at: date(40))
        let found = try await store.search("needle").map(\.title)
        XCTAssertEqual(found, ["needle again"])
        let listed = try await store.page().map(\.title)
        XCTAssertEqual(listed, ["needle again"])
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

        // When a repeat copy has richer formatting, the row grows, and the counter increases with
        // it.
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

    func testEvictionRemovesTheThumbnailOfAFileItem() async throws {
        let file = Fixtures.fileCapture(["/tmp/evicted.mov"])
        _ = try await store.insert(file, at: date(1))
        let png = Fixtures.png(width: 16, height: 16)
        try await store.saveThumbnail(png, for: file.hash)
        let newest = Fixtures.textCapture("newest")
        _ = try await store.insert(newest, at: date(2))

        let removed = try await store.setStorageBudget(newest.byteSize)
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location.thumbnailURL(for: file.hash).path))
        let used = try await store.storageUsage()
        XCTAssertEqual(used, newest.byteSize)
    }

    func testAnEmptyThumbnailIsNotSaved() async throws {
        let image = Fixtures.imageCapture()
        _ = try await store.insert(image)
        let saved = try await store.saveThumbnail(Data(), for: image.hash)
        XCTAssertFalse(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location.thumbnailURL(for: image.hash).path))
        XCTAssertEqual(stagedFiles(), [])
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

    /// Returns a copy of the database file without its log file, showing what survives when the log
    /// file is lost.
    private func databaseFileAlone() throws -> Database {
        let copy = directory.appendingPathComponent("copy-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: store.location.database, to: copy)
        return try Database(path: copy.path)
    }

    func testACleanShutdownLeavesEverythingInTheDatabaseFile() async throws {
        _ = try await store.insert(Fixtures.textCapture("kept through the quit"))
        _ = try await store.beginSession()
        store.markCleanShutdown()

        let copy = try databaseFileAlone()
        XCTAssertEqual(try copy.scalarInt("SELECT count(*) FROM items"), 1)
        XCTAssertEqual(try copy.scalarInt("SELECT clean_shutdown FROM stats WHERE id = 1"), 1)
        XCTAssertEqual(PasteboardClassifier.size(ofFileAt: store.location.database.path + "-wal"), 0)
    }

    func testTheStartOfASessionIsInTheDatabaseFile() async throws {
        store.markCleanShutdown()
        let clean = try await store.beginSession()
        XCTAssertTrue(clean)
        // A session that loses power must read as unclean, or its orphaned files are never swept.
        let copy = try databaseFileAlone()
        XCTAssertEqual(try copy.scalarInt("SELECT clean_shutdown FROM stats WHERE id = 1"), 0)
    }

    func testTheStoreOpensWithoutItsLogFiles() async throws {
        _ = try await store.insert(Fixtures.textCapture("kept"))
        store.markCleanShutdown()
        store = nil
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: directory.appendingPathComponent(Constants.databaseFileName).path + suffix)
        }
        // A stale index file from another session is rebuilt.
        try Data(repeating: 0xA5, count: 32_768).write(to: URL(fileURLWithPath: directory.appendingPathComponent(Constants.databaseFileName).path + "-shm"))
        store = try ClipStore(location: StoreLocation(root: directory))
        let titles = try await store.page().map(\.title)
        XCTAssertEqual(titles, ["kept"])
        _ = try await store.insert(Fixtures.textCapture("added"))
        let count = try await store.count()
        XCTAssertEqual(count, 2)
    }

    func testTheLogFileStaysBounded() async throws {
        let body = String(repeating: "lorem ipsum dolor sit amet ", count: 4_000)
        for index in 0..<300 {
            _ = try await store.insert(Fixtures.textCapture("\(index) \(body)"), at: date(TimeInterval(index)))
        }
        let log = PasteboardClassifier.size(ofFileAt: store.location.database.path + "-wal")
        XCTAssertGreaterThan(log, 0)
        XCTAssertLessThanOrEqual(log, Int64(Constants.Storage.logSizeLimit) + 1_048_576)
        let db = try Database(path: store.location.database.path)
        XCTAssertGreaterThan(PasteboardClassifier.size(ofFileAt: store.location.database.path), 8_000_000, "a checkpoint ran")
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM items"), 300)
    }

    func testTheSessionAfterACrashRepairsWhatTheCrashLeft() async throws {
        let kept = Fixtures.imageCapture(width: 20, height: 20)
        let file = Fixtures.fileCapture(["/tmp/crashed.mov"])
        _ = try await store.beginSession()
        _ = try await store.insert(kept, at: date(1))
        _ = try await store.insert(file, at: date(2))
        let location = store.location
        // A blob moved into place before its row was committed. A write never left staging. A
        // thumbnail moved into place before its size was committed.
        try Data([1, 2, 3]).write(to: location.blobURL(for: "blob-without-a-row"))
        try Data([4, 5]).write(to: location.staging.appendingPathComponent("interrupted"))
        let png = Fixtures.png(width: 3, height: 3)
        try png.write(to: location.thumbnailURL(for: file.hash))
        try png.write(to: location.thumbnailURL(for: "thumbnail-without-a-row"))
        // The process ends here without a clean shutdown.
        store = nil

        store = try ClipStore(location: location)
        XCTAssertEqual(stagedFiles(), [])
        let wasClean = try await store.beginSession()
        XCTAssertFalse(wasClean)
        let removed = try await store.collectGarbage()
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.blobs.path), [kept.hash])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.thumbs.path), ["\(file.hash).png"])
        let used = try await store.storageUsage()
        XCTAssertEqual(used, blobSize(kept) + Int64(png.count))
        let payload = try await store.payload(for: 1)
        XCTAssertEqual(payload?.blob, kept.blob)
        try StoreInspector.assertSound(at: location)

        // The repaired session ends cleanly, and the next one has nothing to repair.
        store.markCleanShutdown()
        store = nil
        store = try ClipStore(location: location)
        let clean = try await store.beginSession()
        XCTAssertTrue(clean)
    }

    func testGarbageCollectionRecountsBytesAndRecordsUnrecordedThumbnails() async throws {
        let image = Fixtures.imageCapture(width: 16, height: 16)
        _ = try await store.insert(image)
        // A manually written thumbnail represents one saved just before a crash and before its size
        // was recorded.
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
        for name in ["items", "representations", "files", "items_fts", "items_recent", "items_seq", "stats"] {
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

    func testMigrationFromVersionFourKeepsRowsFormatsAndSearch() async throws {
        let fresh = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fresh) }
        let location = StoreLocation(root: fresh)
        let long = String(repeating: "lengthy ", count: 100)
        do {
            let old = try Database(path: location.database.path)
            try ClipStore.configure(old)
            try ClipStore.migrate(old, upTo: 4)
            try old.run(
                """
                INSERT INTO items (id, hash, kind, created_at, last_used, title, detail, search_text, byte_size, blob_type, file_count, offers_tiff, offers_plain_text, thumb_size)
                VALUES (1, 'txt', 0, 1, 9, 'alpha note', NULL, 'alpha note', 100, NULL, 0, 0, 0, 0),
                       (2, 'img', 1, 2, 2, 'Image 4\u{00D7}3', NULL, 'Image 4\u{00D7}3', 2000, 'public.png', 0, 1, 0, 50),
                       (3, 'vid', 2, 3, 3, 'clip.mov', '/tmp/clip.mov', '/tmp/clip.mov', 30000, NULL, 1, 0, 0, 7),
                       (4, 'big', 0, 4, 4, 'lengthy', NULL, ?, 800, NULL, 0, 0, 1, 0)
                """,
                [.text(long)]
            )
            try old.run("INSERT INTO representations (item_id, position, type, data) VALUES (1, 0, 'public.rtf', x'7B5C72746631')")
            try old.run("INSERT INTO files (item_id, position, path, bookmark) VALUES (3, 0, '/tmp/clip.mov', x'01')")
            // Only a connection without foreign keys can write rows that refer to no item.
            try old.execute("PRAGMA foreign_keys = OFF")
            try old.run("INSERT INTO representations (item_id, position, type, data) VALUES (99, 0, 'public.rtf', x'00')")
            try old.run("INSERT INTO files (item_id, position, path) VALUES (99, 0, '/tmp/stray')")
            XCTAssertEqual(try old.userVersion(), 4)
            XCTAssertEqual(try old.scalarInt(ClipStore.totalBytesSQL), 100 + 2000 + 50 + 7 + 800)
        }
        try FileManager.default.createDirectory(at: location.blobs, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: location.blobURL(for: "img"))

        let migrated = try ClipStore(location: location)
        let version = try await migrated.schemaVersionOnDisk()
        XCTAssertEqual(version, 5)

        let page = try await migrated.page()
        XCTAssertEqual(page.map(\.id), [1, 4, 3, 2])
        XCTAssertEqual(page.map(\.preview), ["alpha note", String(long.prefix(300)), "/tmp/clip.mov", "Image 4\u{00D7}3"])
        XCTAssertEqual(page.map(\.fileCount), [0, 0, 1, 0])
        XCTAssertEqual(page.map(\.blobType), [nil, nil, nil, "public.png"])
        let used = try await migrated.storageUsage()
        XCTAssertEqual(used, 100 + 2000 + 50 + 7 + 800)

        do {
            let check = try Database(path: location.database.path)
            XCTAssertEqual(try check.scalarInt("SELECT count(*) FROM representations"), 1)
            XCTAssertEqual(try check.scalarInt("SELECT count(*) FROM files"), 1)
        }
        let text = try await migrated.payload(for: 1)
        XCTAssertNil(text?.plainText, "offers_plain_text was 0")
        XCTAssertEqual(text?.representations, [PasteboardRepresentation(type: "public.rtf", data: Data("{\\rtf1".utf8))])
        let file = try await migrated.payload(for: 3)
        XCTAssertEqual(file?.files, [FileReference(path: "/tmp/clip.mov", bookmark: Data([1]))])
        let image = try await migrated.payload(for: 2)
        XCTAssertEqual(image?.blob?.data, Data([1, 2, 3]))
        let whole = try await migrated.payload(for: 4)
        XCTAssertEqual(whole?.plainText, long)

        // Search finds the old rows, newest copy first, and a row copied after the migration.
        let found = try await migrated.search("al").map(\.id)
        XCTAssertEqual(found, [1])
        let fresher = try await migrated.insert(Fixtures.textCapture("alpha again"), at: date(1)).id
        let both = try await migrated.search("alpha").map(\.id)
        XCTAssertEqual(both, [fresher, 1])
        let clips = try await migrated.search("clip mov").map(\.id)
        XCTAssertEqual(clips, [3])

        // The stored bytes total still tracks removals, and removing an item also removes rows that
        // refer to it.
        try await migrated.clear(ClearRequest(range: .allTime, kinds: [.text, .file]))
        let remaining = try await migrated.storageUsage()
        XCTAssertEqual(remaining, 2000 + 50)
        let check = try Database(path: location.database.path)
        XCTAssertEqual(try check.scalarInt("SELECT count(*) FROM representations"), 0)
        XCTAssertEqual(try check.scalarInt("SELECT count(*) FROM files"), 0)
        XCTAssertNil(try check.first("PRAGMA foreign_key_check") { _ in true })
        XCTAssertNil(try check.first("SELECT 1 FROM sqlite_master WHERE name = 'items_v5'") { _ in true })
    }

    func testMigrationFromVersionFourOrdersTheIndexByLastUse() async throws {
        let fresh = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fresh) }
        let location = StoreLocation(root: fresh)
        do {
            let old = try Database(path: location.database.path)
            try ClipStore.configure(old)
            try ClipStore.migrate(old, upTo: 4)
            for (id, lastUsed) in [(1, 30.0), (2, 10.0), (3, 20.0), (4, 20.0)] {
                try old.run(
                    """
                    INSERT INTO items (id, hash, kind, created_at, last_used, title, search_text, byte_size, file_count)
                    VALUES (?1, 'h' || ?1, 0, 1, ?2, 'needle ' || ?1, 'needle ' || ?1, 8, 0)
                    """,
                    [.int(Int64(id)), .double(lastUsed)]
                )
            }
        }
        let migrated = try ClipStore(location: location)
        let listed = try await migrated.page().map(\.id)
        XCTAssertEqual(listed, [1, 4, 3, 2])
        let found = try await migrated.search("needle").map(\.id)
        XCTAssertEqual(found, listed)
        let first = try await migrated.search("needle", limit: 2)
        let rest = try await migrated.search("needle", after: PageCursor(after: first[1]), limit: 2).map(\.id)
        XCTAssertEqual(rest, [3, 2])
    }

    func testConnectionKeepsTheLogFileBetweenCheckpoints() throws {
        let db = try Database(path: directory.appendingPathComponent("pragmas.sqlite").path)
        try ClipStore.configure(db)
        XCTAssertEqual(try db.scalarInt("PRAGMA wal_autocheckpoint"), Int64(Constants.Storage.checkpointPages))
        XCTAssertEqual(try db.scalarInt("PRAGMA journal_size_limit"), Int64(Constants.Storage.logSizeLimit))
        XCTAssertEqual(try db.scalarInt("PRAGMA foreign_keys"), 1)
        let pageSize = try XCTUnwrap(try db.scalarInt("PRAGMA page_size"))
        XCTAssertGreaterThanOrEqual(
            Int64(Constants.Storage.logSizeLimit), Int64(Constants.Storage.checkpointPages) * (pageSize + 24) + 32,
            "a log smaller than one checkpoint interval is cut and grown again every time"
        )
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
        let detail = try plan(ClipStore.idForHashSQL, [.text("h")])
        XCTAssertTrue(detail.contains("INDEX sqlite_autoindex_items"), detail)
        XCTAssertTrue(detail.contains("hash=?"), detail)
        let bump = try plan(ClipStore.bumpSQL, [.double(1), .int(1), .int(0), .int(1), .int(1)])
        XCTAssertTrue(bump.contains("SEARCH items USING INTEGER PRIMARY KEY"), bump)
    }

    func testEvictionScansTheRecentIndexOldestFirst() throws {
        let plan = try plan(ClipStore.oldestSQL, [.int(10)])
        XCTAssertTrue(plan.contains("items_recent"), plan)
        XCTAssertFalse(plan.contains("TEMP B-TREE"), plan)
        let newest = try self.plan(ClipStore.newestSQL, [])
        XCTAssertTrue(newest.contains("items_recent"), newest)
        XCTAssertFalse(newest.contains("TEMP B-TREE"), newest)
        let newestTime = try self.plan(ClipStore.newestTimeSQL, [])
        XCTAssertTrue(newestTime.contains("COVERING INDEX items_recent"), newestTime)
        XCTAssertFalse(newestTime.contains("TEMP B-TREE"), newestTime)
        let owner = try self.plan(ClipStore.thumbnailOwnerSQL, [.text("h")])
        XCTAssertTrue(owner.contains("INDEX sqlite_autoindex_items"), owner)
    }

    func testSearchUsesTheFullTextIndex() throws {
        let detail = try plan(ClipStore.searchSQL, [.text("\"abc\"*"), .int(.max), .int(100)])
        XCTAssertTrue(detail.contains("items_fts VIRTUAL TABLE INDEX"), detail)
        XCTAssertTrue(detail.contains("USING INDEX items_seq (seq=?)"), detail)
        XCTAssertFalse(detail.contains("SCAN items "), detail)
        XCTAssertFalse(detail.contains("TEMP B-TREE"), detail)
    }

    func testSearchCursorLookupsUseIndexes() throws {
        let exact = try plan(ClipStore.cursorSequenceSQL, [.int(1), .double(1)])
        XCTAssertTrue(exact.contains("USING INTEGER PRIMARY KEY"), exact)
        let before = try plan(ClipStore.sequenceBeforeSQL, [.double(1), .int(1)])
        XCTAssertTrue(before.contains("items_recent"), before)
        XCTAssertFalse(before.contains("TEMP B-TREE"), before)
    }

    func testWritesFindTheNextSequenceNumberInTheIndex() throws {
        let values: [String: [SQLValue]] = [
            ClipStore.touchSQL: [.double(1), .int(1)],
            ClipStore.bumpSQL: [.double(1), .int(1), .int(0), .int(1), .int(1)],
            ClipStore.insertSQL: [
                .text("h"), .int(0), .double(1), .text("t"), .null, .text("t"), .int(1), .null, .int(0), .int(0), .int(1),
            ],
        ]
        for (sql, bindings) in values {
            let detail = try plan(sql, bindings)
            XCTAssertTrue(detail.contains("USING COVERING INDEX items_seq"), detail)
            XCTAssertFalse(detail.contains("SCAN items"), detail)
        }
    }

    func testRemovalsWalkTheSequenceIndex() throws {
        let statements: [(String, [SQLValue])] = [
            (ClipStore.evictSQL, [.text("[1,2]")]),
            (ClipStore.deleteSQL(where: "kind IN (0, 1) AND last_used >= ?"), [.double(1)]),
            (ClipStore.deleteSQL(where: "kind IN (0)"), []),
            (ClipStore.deleteSQL(where: ""), []),
        ]
        for (sql, values) in statements {
            let detail = try plan(sql, values)
            XCTAssertTrue(detail.hasPrefix("SEARCH items USING COVERING INDEX items_seq (seq=?)"), detail)
            XCTAssertFalse(detail.contains("SCAN items |"), detail)
        }
        let eviction = try plan(ClipStore.evictSQL, [.text("[1,2]")])
        XCTAssertTrue(eviction.contains("USING INTEGER PRIMARY KEY"), eviction)
    }

    func testIndexRebuildReadsRowsWithoutSortingThem() throws {
        let fill = try plan("SELECT seq, search_text FROM items INDEXED BY items_seq ORDER BY seq", [])
        XCTAssertTrue(fill.contains("items_seq"), fill)
        XCTAssertFalse(fill.contains("TEMP B-TREE"), fill)
        let order = try plan("SELECT id, row_number() OVER (ORDER BY last_used, id) FROM items", [])
        XCTAssertTrue(order.contains("COVERING INDEX items_recent"), order)
        XCTAssertFalse(order.contains("TEMP B-TREE"), order)
    }

    func testPayloadAndCountReadByKeyOrIndex() throws {
        let payload = try plan(ClipStore.payloadSQL, [.int(1)])
        XCTAssertTrue(payload.contains("USING INTEGER PRIMARY KEY"), payload)
        let count = try plan(ClipStore.countSQL, [])
        XCTAssertTrue(count.contains("COVERING INDEX"), count)
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

    func testStoreErrorsDescribeThemselves() {
        let newer: Error = StoreError.newerSchema(9)
        XCTAssertEqual(newer.localizedDescription, "This history was saved by a newer version of ClipDeck.")
        XCTAssertEqual(newer.advice, "Update ClipDeck to open it.")
        let full: Error = SQLiteError(code: 13, message: "database or disk is full")
        XCTAssertEqual(
            full.localizedDescription,
            "The disk is full, so the history can't be saved (SQLite error 13: database or disk is full)."
        )
        XCTAssertEqual(full.advice, "Free some space on the disk.")
        XCTAssertEqual(full.explanation, full.localizedDescription + " Free some space on the disk.")
        let damaged: Error = SQLiteError(code: 11, message: "database disk image is malformed")
        XCTAssertTrue(damaged.localizedDescription.hasPrefix("The history database is damaged ("), damaged.localizedDescription)
        XCTAssertEqual(
            damaged.advice,
            "Quit ClipDeck. Move the ClipDeck folder from ~/Library/Application Support to another folder to start with "
                + "an empty history."
        )
        // An extended code describes itself in the same way as its primary code.
        let io: Error = SQLiteError(code: 10 | (4 << 8), message: "disk I/O error")
        XCTAssertTrue(io.localizedDescription.hasPrefix("ClipDeck encountered a disk error"), io.localizedDescription)
        let other: Error = SQLiteError(code: 1, message: "no such table: nope")
        XCTAssertEqual(other.localizedDescription, "The history database reported an error (SQLite error 1: no such table: nope).")
        XCTAssertNil(other.advice)
        XCTAssertEqual(other.explanation, other.localizedDescription)
        for error in [newer, full, damaged, io, other] {
            XCTAssertFalse(error.localizedDescription.contains("error 0"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("ClipDeck.SQLiteError"), error.localizedDescription)
        }
        XCTAssertEqual(String(describing: SQLiteError(code: 1, message: "no such table: nope")), "SQLite error 1: no such table: nope")
    }

    func testAFailedOpenReportsWhatSQLiteSaid() throws {
        let fresh = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fresh) }
        let location = StoreLocation(root: fresh)
        try Data(repeating: 0x5A, count: 8_192).write(to: location.database)
        XCTAssertThrowsError(try ClipStore(location: location)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("The history database is damaged ("), error.localizedDescription)
        }
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

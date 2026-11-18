import Combine
import XCTest
@testable import ClipDeck

@MainActor
final class HistoryViewModelTests: XCTestCase {
    private var directory: URL!
    private var store: ClipStore!
    private var viewModel: HistoryViewModel!

    override func setUp() async throws {
        directory = Fixtures.temporaryDirectory()
        store = try ClipStore(location: StoreLocation(root: directory))
        for index in 0..<250 {
            _ = try await store.insert(
                Fixtures.textCapture("row \(index)"),
                at: Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(index))
            )
        }
        viewModel = HistoryViewModel(store: store)
    }

    override func tearDown() async throws {
        viewModel = nil
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition not met in time", file: file, line: line)
    }

    func testShowingLoadsOnePageAndSelectsTheNewest() async {
        viewModel.panelWillShow()
        await waitUntil { self.viewModel.items.count == Constants.List.pageSize }
        XCTAssertEqual(viewModel.items.first?.title, "row 249")
        XCTAssertEqual(viewModel.selectedID, viewModel.items.first?.id)
        XCTAssertEqual(viewModel.selectedItem?.title, "row 249")
    }

    func testMovingSelectionStaysInBounds() async {
        viewModel.panelWillShow()
        await waitUntil { self.viewModel.items.count == Constants.List.pageSize }

        viewModel.moveSelection(by: -1)
        XCTAssertEqual(viewModel.selectedItem?.title, "row 249")
        viewModel.moveSelection(by: 5)
        XCTAssertEqual(viewModel.selectedItem?.title, "row 244")
        viewModel.moveSelection(by: -2)
        XCTAssertEqual(viewModel.selectedItem?.title, "row 246")
    }

    func testLoadMoreAppendsTheNextPageWithoutDuplicates() async {
        viewModel.panelWillShow()
        await waitUntil { self.viewModel.items.count == Constants.List.pageSize }

        viewModel.loadMoreIfNeeded(after: viewModel.items[viewModel.items.count - 1])
        await waitUntil { self.viewModel.items.count == 2 * Constants.List.pageSize }
        viewModel.loadMoreIfNeeded(after: viewModel.items[viewModel.items.count - 1])
        await waitUntil { self.viewModel.items.count == 250 }

        XCTAssertEqual(Set(viewModel.items.map(\.id)).count, 250)
        XCTAssertEqual(viewModel.items.last?.title, "row 0")
        viewModel.select(viewModel.items[230])
        XCTAssertEqual(viewModel.selectedItem?.title, "row 19")
    }

    func testRowsFarFromTheEndDoNotLoadMore() async throws {
        viewModel.panelWillShow()
        await waitUntil { self.viewModel.items.count == Constants.List.pageSize }
        viewModel.loadMoreIfNeeded(after: viewModel.items[0])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(viewModel.items.count, Constants.List.pageSize)
    }

    func testArrowingNearTheEndLoadsMore() async {
        viewModel.panelWillShow()
        await waitUntil { self.viewModel.items.count == Constants.List.pageSize }
        viewModel.moveSelection(by: Constants.List.pageSize - Constants.List.loadMoreThreshold)
        await waitUntil { self.viewModel.items.count == 2 * Constants.List.pageSize }
    }

    func testSearchFiltersAfterTheDebounce() async {
        viewModel.panelWillShow()
        await waitUntil { self.viewModel.items.count == Constants.List.pageSize }

        viewModel.query = "row 0"
        await waitUntil { self.viewModel.items.count == 1 }
        XCTAssertEqual(viewModel.items.first?.title, "row 0")
        XCTAssertTrue(viewModel.isSearching)
        XCTAssertEqual(viewModel.selectedItem?.title, "row 0")
    }

    func testOneCharacterDoesNotSearch() async throws {
        viewModel.panelWillShow()
        await waitUntil { self.viewModel.items.count == Constants.List.pageSize }

        viewModel.query = "r"
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(viewModel.isSearching)
        XCTAssertEqual(viewModel.items.count, Constants.List.pageSize)
        XCTAssertEqual(viewModel.items.first?.title, "row 249")
    }

    // MARK: - History changes

    private func showFirstPage() async {
        viewModel.panelWillShow()
        await waitUntil { self.viewModel.items.count == Constants.List.pageSize }
    }

    private func loadPages(_ pages: Int) async {
        for page in 2...pages {
            viewModel.loadMoreIfNeeded(after: viewModel.items[viewModel.items.count - 1])
            await waitUntil { self.viewModel.items.count == min(page * Constants.List.pageSize, 250) }
        }
    }

    /// Once this returns, the view model has finished and applied every reload it started.
    private func settle() async throws {
        for _ in 0..<3 {
            for _ in 0..<5 { await Task.yield() }
            _ = try await store.count()
        }
        for _ in 0..<5 { await Task.yield() }
    }

    private func insert(_ title: String) async throws {
        _ = try await store.insert(Fixtures.textCapture(title), at: Date(timeIntervalSince1970: 1_900_000_000))
    }

    func testHistoryChangeKeepsTheLoadedRowsAndTheSelection() async throws {
        await showFirstPage()
        await loadPages(2)
        viewModel.select(viewModel.items[150])
        let selected = viewModel.selectedID

        try await insert("fresh")
        viewModel.historyDidChange()
        await waitUntil { self.viewModel.items.first?.title == "fresh" }

        XCTAssertEqual(viewModel.items.count, 201)
        XCTAssertEqual(Set(viewModel.items.map(\.id)).count, 201)
        XCTAssertEqual(viewModel.items.last?.title, "row 50")
        XCTAssertEqual(viewModel.selectedID, selected)
        XCTAssertEqual(viewModel.selectedItem?.title, "row 99")
    }

    func testHistoryChangeWithNothingNewPublishesNothing() async throws {
        await showFirstPage()
        await loadPages(2)
        try await settle()
        var publishes = 0
        let subscription = viewModel.objectWillChange.sink { publishes += 1 }
        defer { subscription.cancel() }
        let token = viewModel.refreshToken

        viewModel.historyDidChange()
        try await settle()

        XCTAssertEqual(publishes, 0)
        XCTAssertEqual(viewModel.refreshToken, token)
        XCTAssertEqual(viewModel.items.count, 200)
    }

    func testANewRowPublishesOnceAndLeavesTheThumbnailTokenAlone() async throws {
        await showFirstPage()
        try await settle()
        var publishes = 0
        let subscription = viewModel.objectWillChange.sink { publishes += 1 }
        defer { subscription.cancel() }
        let token = viewModel.refreshToken

        try await insert("fresh")
        viewModel.historyDidChange()
        await waitUntil { self.viewModel.items.first?.title == "fresh" }
        try await settle()

        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(viewModel.refreshToken, token)
        XCTAssertEqual(viewModel.items.count, 101)
    }

    func testACopiedRowMovesToTheTopWithoutADuplicate() async throws {
        await showFirstPage()
        await loadPages(2)
        let moved = viewModel.items[170]

        try await store.touch(id: moved.id, at: Date(timeIntervalSince1970: 1_900_000_000))
        viewModel.historyDidChange()
        await waitUntil { self.viewModel.items.first?.id == moved.id }

        XCTAssertEqual(viewModel.items.count, 200)
        XCTAssertEqual(Set(viewModel.items.map(\.id)).count, 200)
        let expected = try await allIDs(limit: 200)
        XCTAssertEqual(viewModel.items.map(\.id), expected)
    }

    func testTheOldestLoadedRowMovingToTheTopKeepsTheRest() async throws {
        await showFirstPage()
        await loadPages(2)
        let moved = viewModel.items[199]

        try await store.touch(id: moved.id, at: Date(timeIntervalSince1970: 1_900_000_000))
        viewModel.historyDidChange()
        await waitUntil { self.viewModel.items.first?.id == moved.id }

        let expected = try await allIDs(limit: 200)
        XCTAssertEqual(viewModel.items.map(\.id), expected)
    }

    func testRowsTheStoreEvictedLeaveTheList() async throws {
        await showFirstPage()
        await loadPages(3)
        XCTAssertEqual(viewModel.items.count, 250)

        let usage = try await store.storageUsage()
        let removed = try await store.setStorageBudget(usage / 2)
        XCTAssertGreaterThan(removed, 0)
        viewModel.historyDidChange()
        try await settle()

        let remaining = try await allIDs(limit: 250)
        XCTAssertEqual(remaining.count, 250 - removed)
        XCTAssertTrue(Set(viewModel.items.map(\.id)).isSubset(of: Set(remaining)))
        XCTAssertEqual(viewModel.items.map(\.id), Array(remaining.prefix(viewModel.items.count)))
    }

    func testAHistoryThatShrinksBelowOnePageReplacesTheList() async throws {
        await showFirstPage()
        await loadPages(2)
        _ = try await store.clear(ClearRequest(range: .allTime, kinds: Set(ClipKind.allCases)))
        try await insert("only row")
        viewModel.historyDidChange()
        await waitUntil { self.viewModel.items.count == 1 }
        XCTAssertEqual(viewModel.selectedItem?.title, "only row")
    }

    func testPositionsStayRightThroughMergesAndPaging() async throws {
        await showFirstPage()
        await loadPages(2)
        for index in 0..<3 {
            _ = try await store.insert(Fixtures.textCapture("fresh \(index)"), at: Date(timeIntervalSince1970: 1_900_000_000 + TimeInterval(index)))
            viewModel.historyDidChange()
            await waitUntil { self.viewModel.items.first?.title == "fresh \(index)" }
        }
        try await settle()
        viewModel.loadMoreIfNeeded(after: viewModel.items[viewModel.items.count - 1])
        await waitUntil { self.viewModel.items.count == 253 }
        try await store.touch(id: viewModel.items[120].id, at: Date(timeIntervalSince1970: 1_900_000_100))
        viewModel.historyDidChange()
        try await settle()

        let expected = try await allIDs(limit: 300)
        XCTAssertEqual(viewModel.items.map(\.id), expected)
        for item in viewModel.items {
            viewModel.select(item)
            XCTAssertEqual(viewModel.selectedItem, item)
        }
        viewModel.select(viewModel.items[150])
        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedID, viewModel.items[151].id)
        viewModel.moveSelection(by: -151)
        XCTAssertEqual(viewModel.selectedID, viewModel.items[0].id)
    }

    private func allIDs(limit: Int) async throws -> [Int64] {
        try await store.page(limit: limit).map(\.id)
    }

    // MARK: - Thumbnails

    func testASavedThumbnailChangesTheTokenOnlyWhileThePanelIsOpen() async {
        await showFirstPage()
        let token = viewModel.refreshToken
        NotificationCenter.default.post(name: .clipThumbnailDidChange, object: "hash")
        XCTAssertEqual(viewModel.refreshToken, token + 1)

        viewModel.panelDidHide()
        NotificationCenter.default.post(name: .clipThumbnailDidChange, object: "hash")
        XCTAssertEqual(viewModel.refreshToken, token + 1)

        viewModel.panelWillShow()
        XCTAssertEqual(viewModel.refreshToken, token + 2, "opening the panel retries thumbnails saved while it was closed")
    }

    // MARK: - Coalescing

    func testABurstOfHistoryChangesSharesItsReads() async throws {
        let recorder = FetchRecorder(store: store)
        viewModel = HistoryViewModel(store: store, fetch: recorder.fetch)
        await showFirstPage()
        try await settle()
        recorder.reset()

        for _ in 0..<50 { viewModel.historyDidChange() }
        try await settle()
        XCTAssertLessThanOrEqual(recorder.firstPageReads, 2)
        XCTAssertGreaterThanOrEqual(recorder.firstPageReads, 1)

        recorder.reset()
        try await insert("fresh")
        for _ in 0..<50 { viewModel.historyDidChange() }
        await waitUntil { self.viewModel.items.first?.title == "fresh" }
        try await settle()
        XCTAssertLessThanOrEqual(recorder.firstPageReads, 2)
    }

    func testTypingDoesNotQueueSearchesBehindASlowOne() async throws {
        let recorder = FetchRecorder(store: store)
        viewModel = HistoryViewModel(store: store, fetch: recorder.fetch)
        await showFirstPage()
        try await settle()
        recorder.reset()

        recorder.holdSearches()
        viewModel.query = "ro"
        await waitUntil { recorder.searches == ["ro"] }
        for text in ["row", "row 1", "row 12"] {
            viewModel.query = text
            try await Task.sleep(for: Constants.List.searchDebounce * 3)
        }
        XCTAssertEqual(recorder.searches, ["ro"], "later searches wait for the one in flight")
        recorder.releaseSearches()

        await waitUntil { self.viewModel.items.count == 11 }
        XCTAssertEqual(recorder.searches, ["ro", "row 12"])
        XCTAssertEqual(viewModel.items.first?.title, "row 129")
    }

    func testAKeystrokeThatLeavesTheSearchTextAloneDoesNotReload() async throws {
        let recorder = FetchRecorder(store: store)
        viewModel = HistoryViewModel(store: store, fetch: recorder.fetch)
        await showFirstPage()
        viewModel.query = "row 12"
        await waitUntil { self.viewModel.items.count == 11 }
        viewModel.moveSelection(by: 3)
        let selected = viewModel.selectedID
        recorder.reset()

        viewModel.query = "row 12 "
        try await Task.sleep(for: Constants.List.searchDebounce * 3)
        XCTAssertEqual(recorder.firstPageReads, 0)
        XCTAssertEqual(viewModel.selectedID, selected)
    }

    func testHidingThePanelDropsAReloadInFlight() async throws {
        let recorder = FetchRecorder(store: store)
        viewModel = HistoryViewModel(store: store, fetch: recorder.fetch)
        recorder.holdFirstPages()
        viewModel.panelWillShow()
        await waitUntil { recorder.firstPageReads == 1 }
        viewModel.panelDidHide()
        viewModel.historyDidChange()
        recorder.releaseFirstPages()
        try await settle()

        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertEqual(recorder.firstPageReads, 1)

        viewModel.panelWillShow()
        await waitUntil { self.viewModel.items.count == Constants.List.pageSize }
    }

    func testANextPageInFlightSurvivesAHistoryChange() async throws {
        let recorder = FetchRecorder(store: store)
        viewModel = HistoryViewModel(store: store, fetch: recorder.fetch)
        await showFirstPage()
        try await settle()

        recorder.holdNextPages()
        viewModel.loadMoreIfNeeded(after: viewModel.items[99])
        await waitUntil { recorder.nextPageReads == 1 }
        try await insert("fresh")
        viewModel.historyDidChange()
        await waitUntil { self.viewModel.items.first?.title == "fresh" }
        XCTAssertEqual(viewModel.items.count, 101)
        recorder.releaseNextPages()

        await waitUntil { self.viewModel.items.count == 201 }
        let expected = try await allIDs(limit: 201)
        XCTAssertEqual(viewModel.items.map(\.id), expected)
    }

    func testAFailedReloadLeavesTheListAndTheNextOneWorks() async throws {
        let recorder = FetchRecorder(store: store)
        viewModel = HistoryViewModel(store: store, fetch: recorder.fetch)
        await showFirstPage()
        try await settle()

        recorder.failNext()
        try await insert("fresh")
        viewModel.historyDidChange()
        try await settle()
        XCTAssertEqual(viewModel.items.count, Constants.List.pageSize)
        XCTAssertNotEqual(viewModel.items.first?.title, "fresh")
        XCTAssertTrue(viewModel.loadFailed, "the rows on screen are known to be out of date")
        XCTAssertNotNil(viewModel.selectedItem, "the rows a failed merge kept can still be copied")

        viewModel.historyDidChange()
        await waitUntil { self.viewModel.items.first?.title == "fresh" }
        XCTAssertFalse(viewModel.loadFailed)
    }

    // MARK: - Load state

    func testNothingCountsAsLoadedUntilTheFirstPageArrives() async throws {
        let recorder = FetchRecorder(store: store)
        viewModel = HistoryViewModel(store: store, fetch: recorder.fetch)
        recorder.holdFirstPages()
        viewModel.panelWillShow()
        await waitUntil { recorder.firstPageReads == 1 }
        XCTAssertFalse(viewModel.hasLoaded, "an empty list here is a list on its way")
        XCTAssertGreaterThan(viewModel.refreshToken, 0, "the thumbnail token does not say whether rows loaded")

        recorder.releaseFirstPages()
        await waitUntil { self.viewModel.hasLoaded }
        XCTAssertEqual(viewModel.items.count, Constants.List.pageSize)
        XCTAssertFalse(viewModel.loadFailed)
    }

    func testAFailedFirstPageIsPublishedAndClearedByTheNextLoad() async throws {
        let recorder = FetchRecorder(store: store)
        viewModel = HistoryViewModel(store: store, fetch: recorder.fetch)
        recorder.failEveryRead(true)
        viewModel.panelWillShow()
        await waitUntil { self.viewModel.loadFailed }
        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertNil(viewModel.selectedItem)

        recorder.failEveryRead(false)
        viewModel.historyDidChange()
        await waitUntil { !self.viewModel.loadFailed }
        XCTAssertEqual(viewModel.items.count, Constants.List.pageSize)
        XCTAssertEqual(viewModel.selectedItem?.title, "row 249")
    }

    func testAFailedSearchShowsNoRowsFromTheSearchBeforeIt() async throws {
        let recorder = FetchRecorder(store: store)
        viewModel = HistoryViewModel(store: store, fetch: recorder.fetch)
        await showFirstPage()
        try await settle()

        recorder.failEveryRead(true)
        viewModel.query = "row 12"
        await waitUntil { self.viewModel.loadFailed }
        XCTAssertTrue(viewModel.items.isEmpty, "the full history is not the result of this search")
        XCTAssertNil(viewModel.selectedID, "Return has nothing to copy")

        recorder.failEveryRead(false)
        viewModel.query = "row 123"
        await waitUntil { self.viewModel.items.count == 1 }
        XCTAssertFalse(viewModel.loadFailed)
        XCTAssertEqual(viewModel.selectedItem?.title, "row 123")
    }

    func testAFailedReloadPublishesTheFailureOnce() async throws {
        let recorder = FetchRecorder(store: store)
        viewModel = HistoryViewModel(store: store, fetch: recorder.fetch)
        await showFirstPage()
        try await settle()
        var publishes = 0
        let subscription = viewModel.objectWillChange.sink { publishes += 1 }
        defer { subscription.cancel() }

        recorder.failEveryRead(true)
        for _ in 0..<3 {
            viewModel.historyDidChange()
            try await settle()
        }
        XCTAssertTrue(viewModel.loadFailed)
        XCTAssertEqual(publishes, 1, "a failure that repeats does not redraw the panel again")
    }

    // MARK: - Search

    func testTheFirstKeystrokeAfterAPauseSearchesAtOnce() async throws {
        let recorder = FetchRecorder(store: store)
        viewModel = HistoryViewModel(store: store, fetch: recorder.fetch)
        await showFirstPage()
        try await settle()
        recorder.reset()

        viewModel.query = "row 12"
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(recorder.searches, ["row 12"], "the search did not wait out the debounce")
        await waitUntil { self.viewModel.items.count == 11 }
    }

    func testKeystrokesCloseTogetherShareOneSearchAfterTheLast() async throws {
        let recorder = FetchRecorder(store: store)
        viewModel = HistoryViewModel(store: store, fetch: recorder.fetch)
        await showFirstPage()
        try await settle()
        recorder.reset()

        viewModel.query = "ro"
        viewModel.query = "row"
        viewModel.query = "row 1"
        viewModel.query = "row 12"
        await waitUntil { self.viewModel.items.count == 11 }
        try await Task.sleep(for: Constants.List.searchDebounce * 3)
        XCTAssertEqual(recorder.searches, ["ro", "row 12"])
    }

    /// Search rows in the order the store returns them.
    private func searchIDs(_ text: String, limit: Int) async throws -> [Int64] {
        try await store.search(text, limit: limit).map(\.id)
    }

    private func showSearch(_ text: String, pages: Int) async throws {
        viewModel.panelWillShow()
        viewModel.query = text
        try await Task.sleep(for: Constants.List.searchDebounce * 2)
        try await settle()
        await waitUntil { self.viewModel.isSearching && self.viewModel.items.count == Constants.List.pageSize }
        for page in 1..<pages {
            viewModel.loadMoreIfNeeded(after: viewModel.items[viewModel.items.count - 1])
            await waitUntil { self.viewModel.items.count == (page + 1) * Constants.List.pageSize }
        }
    }

    func testSearchPagesFollowTheStoreOrder() async throws {
        try await showSearch("row", pages: 2)
        viewModel.loadMoreIfNeeded(after: viewModel.items[viewModel.items.count - 1])
        await waitUntil { self.viewModel.items.count == 250 }
        let expected = try await searchIDs("row", limit: 300)
        XCTAssertEqual(viewModel.items.map(\.id), expected)
    }

    func testARepeatCopyDuringASearchMovesTheRowWithoutADuplicate() async throws {
        try await showSearch("row", pages: 2)
        viewModel.select(viewModel.items[120])
        let selected = viewModel.selectedID
        let moved = viewModel.items[150]

        let outcome = try await store.insert(Fixtures.textCapture(moved.title), at: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(outcome, .bumped(moved.id))
        viewModel.historyDidChange()
        await waitUntil { self.viewModel.items.first?.id == moved.id }
        try await settle()

        let expected = try await searchIDs("row", limit: 200)
        XCTAssertEqual(viewModel.items.map(\.id), expected)
        XCTAssertEqual(viewModel.selectedID, selected)
        XCTAssertEqual(viewModel.selectedIndex, 121, "the selected row moved down by the one above it")
    }

    func testATouchDuringASearchKeepsTheRowsAndPagesOn() async throws {
        try await showSearch("row", pages: 2)
        let moved = viewModel.items[199]
        viewModel.select(viewModel.items[60])
        let selected = viewModel.selectedID

        try await store.touch(id: moved.id, at: Date(timeIntervalSince1970: 1_900_000_000))
        viewModel.historyDidChange()
        await waitUntil { self.viewModel.items.first?.id == moved.id }
        try await settle()
        XCTAssertEqual(viewModel.selectedID, selected)

        viewModel.loadMoreIfNeeded(after: viewModel.items[viewModel.items.count - 1])
        await waitUntil { self.viewModel.items.count == 250 }
        let expected = try await searchIDs("row", limit: 300)
        XCTAssertEqual(viewModel.items.map(\.id), expected)
        XCTAssertEqual(Set(viewModel.items.map(\.id)).count, 250)
    }

    /// The clock ran ahead for a while and was then set back. The store gives each copy a later
    /// date than the copy before it, so the search and the history stay in one order.
    func testASearchMergeKeepsEveryLoadedRowAfterTheClockWasSetBack() async throws {
        let ahead = 2_000_000_000.0, corrected = 1_900_000_000.0
        for index in 0..<100 {
            _ = try await store.insert(Fixtures.textCapture("row ahead \(index)"), at: Date(timeIntervalSince1970: ahead + TimeInterval(index)))
        }
        for index in 0..<110 {
            _ = try await store.insert(Fixtures.textCapture("row back \(index)"), at: Date(timeIntervalSince1970: corrected + TimeInterval(index)))
        }
        try await showSearch("row", pages: 3)
        let before = try await searchIDs("row", limit: 300)
        XCTAssertEqual(viewModel.items.map(\.id), before)
        let history = try await allIDs(limit: 300)
        XCTAssertEqual(before, history, "every row matches, so the search lists what the history lists")
        XCTAssertEqual(viewModel.items[0].title, "row back 109", "the newest copy is first, whatever its date was")
        XCTAssertTrue(datesFallInOrder(viewModel.items))
        viewModel.select(viewModel.items[150])
        let selected = viewModel.selectedID
        XCTAssertEqual(viewModel.selectedItem?.title, "row ahead 59")

        _ = try await store.insert(Fixtures.textCapture("row fresh"), at: Date(timeIntervalSince1970: corrected + 500))
        viewModel.historyDidChange()
        await waitUntil { self.viewModel.items.first?.title == "row fresh" }
        try await settle()

        let expected = try await searchIDs("row", limit: 301)
        let historyAfter = try await allIDs(limit: 301)
        XCTAssertEqual(viewModel.items.count, 301)
        XCTAssertEqual(viewModel.items.map(\.id), expected, "no loaded row was dropped or repeated")
        XCTAssertEqual(expected, historyAfter)
        XCTAssertTrue(datesFallInOrder(viewModel.items))
        XCTAssertEqual(viewModel.selectedID, selected)
        XCTAssertEqual(viewModel.selectedItem?.title, "row ahead 59")
    }

    /// Check whether each row carries a later date than the row below it.
    private func datesFallInOrder(_ rows: [ClipItem]) -> Bool {
        zip(rows, rows.dropFirst()).allSatisfy { $0.lastUsed > $1.lastUsed }
    }

    /// The dates for copies, repeat copies, and touches jump forward and back. A merge follows each
    /// action. The loaded rows must always match the first rows returned by the store. The store
    /// must keep the history and search results in the same order, with the newest copy first.
    func testBothListsStayInCopyOrderThroughCopiesDatedOutOfOrder() async throws {
        for text in ["row", ""] {
            viewModel.panelWillShow()
            viewModel.query = text
            try await Task.sleep(for: Constants.List.searchDebounce * 2)
            try await settle()
            await waitUntil { self.viewModel.items.count == Constants.List.pageSize }
            var state: UInt64 = text.isEmpty ? 0x9E37_79B9_7F4A_7C15 : 0x2545_F491_4F6C_DD1D
            func next(_ bound: Int) -> Int {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int((state >> 33) % UInt64(bound))
            }
            var clock = 1_900_000_000.0
            for step in 0..<60 {
                clock += Double(next(2_000_001) - 1_000_000)
                let date = Date(timeIntervalSince1970: clock + Double(step) / 1_000)
                let loaded = viewModel.items
                var copied: Int64?
                switch next(5) {
                case 0:
                    copied = try await store.insert(Fixtures.textCapture("row new \(text.count) \(step)"), at: date).id
                case 1:
                    copied = try await store.insert(Fixtures.textCapture(loaded[next(loaded.count)].title), at: date).id
                case 2:
                    let touched = loaded[next(loaded.count)].id
                    copied = touched
                    try await store.touch(id: touched, at: date)
                case 3:
                    copied = loaded[loaded.count - 1].id
                    try await store.touch(id: loaded[loaded.count - 1].id, at: date)
                default:
                    viewModel.loadMoreIfNeeded(after: loaded[loaded.count - 1])
                }
                viewModel.select(viewModel.items[next(viewModel.items.count)])
                viewModel.historyDidChange()
                try await settle()
                try await settle()

                let rows = viewModel.items
                let expected = text.isEmpty
                    ? try await store.page(limit: rows.count)
                    : try await store.search(text, limit: rows.count)
                XCTAssertEqual(rows.map(\.id), expected.map(\.id), "step \(step) of \(text.isEmpty ? "the history" : "the search")")
                // Every row in this store matches "row", so both lists contain the same rows.
                let history = try await store.page(limit: rows.count)
                let search = try await store.search("row", limit: rows.count)
                XCTAssertEqual(history.map(\.id), search.map(\.id), "step \(step) put the two lists in different orders")
                XCTAssertTrue(datesFallInOrder(rows), "step \(step) left a date out of order")
                if let copied { XCTAssertEqual(rows.first?.id, copied, "step \(step): the newest copy is first") }
                XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "step \(step) repeated a row")
                XCTAssertGreaterThanOrEqual(rows.count, Constants.List.pageSize)
                let selected = try XCTUnwrap(viewModel.selectedIndex, "step \(step) lost the selection")
                XCTAssertEqual(rows[selected].id, viewModel.selectedID)
                if rows.map(\.id) != expected.map(\.id) { return }
            }
            viewModel.panelDidHide()
        }
    }

    func testACopyDatedInThePastIsListedFirstInTheHistory() async throws {
        await showFirstPage()
        await loadPages(2)
        viewModel.select(viewModel.items[150])
        let selected = viewModel.selectedID
        let newest = try XCTUnwrap(viewModel.items.first)

        _ = try await store.insert(Fixtures.textCapture("set back"), at: Date(timeIntervalSince1970: 1_800_000_200.5))
        viewModel.historyDidChange()
        await waitUntil { self.viewModel.items.count == 201 }

        let expected = try await allIDs(limit: 201)
        XCTAssertEqual(viewModel.items.map(\.id), expected)
        XCTAssertEqual(viewModel.items[0].title, "set back")
        XCTAssertGreaterThan(viewModel.items[0].lastUsed, newest.lastUsed, "the store raised the date above the newest row's")
        XCTAssertEqual(viewModel.items[1].id, newest.id)
        XCTAssertTrue(datesFallInOrder(viewModel.items))
        XCTAssertEqual(viewModel.selectedID, selected)
        XCTAssertEqual(viewModel.selectedIndex, 151)
    }

    // MARK: - A whole page of changes

    /// The last row of the fresh page marks its own position because it is loaded and was not
    /// copied again. A loaded row above that position that the page does not contain has left the
    /// store.
    func testARowClearedAboveTheLastRowOfThePageLeavesTheList() async throws {
        _ = try await store.insert(Fixtures.fileCapture(["/tmp/row report.pdf"]), at: Date(timeIntervalSince1970: 1_900_000_000))
        for text in ["", "row"] {
            if text.isEmpty {
                await showFirstPage()
                await loadPages(2)
            } else {
                try await showSearch(text, pages: 2)
            }
            let loaded = viewModel.items
            viewModel.select(loaded[150])
            let selected = viewModel.selectedID

            if text.isEmpty {
                XCTAssertEqual(loaded.first?.kind, .file)
            } else {
                // Here, the row to clear sits below a row copied later.
                _ = try await store.insert(Fixtures.fileCapture(["/tmp/row notes.pdf"]), at: Date(timeIntervalSince1970: 1_900_000_001))
                viewModel.historyDidChange()
                await waitUntil { self.viewModel.items.first?.kind == .file }
                try await store.touch(id: viewModel.items[5].id, at: Date(timeIntervalSince1970: 1_900_000_002))
                viewModel.historyDidChange()
                await waitUntil { self.viewModel.items.first?.kind == .text }
                XCTAssertEqual(viewModel.items[1].kind, .file)
            }
            _ = try await store.clear(ClearRequest(range: .allTime, kinds: [.file]))
            viewModel.historyDidChange()
            await waitUntil { !self.viewModel.items.contains { $0.kind == .file } }
            try await settle()

            let rows = viewModel.items
            let expected = text.isEmpty ? try await allIDs(limit: rows.count) : try await searchIDs(text, limit: rows.count)
            XCTAssertEqual(rows.map(\.id), expected, text.isEmpty ? "the history" : "the search")
            XCTAssertGreaterThanOrEqual(rows.count, 199, "the rows loaded below the page stay")
            XCTAssertEqual(viewModel.selectedID, selected)
            viewModel.panelDidHide()
        }
    }

    /// The last row of the fresh page is new, so every loaded row comes after the page.
    func testAWholePageOfNewRowsGoesAboveTheLoadedRows() async throws {
        for text in ["", "row"] {
            if text.isEmpty {
                await showFirstPage()
                await loadPages(2)
            } else {
                try await showSearch(text, pages: 2)
            }
            let loaded = viewModel.items.map(\.id)
            viewModel.select(viewModel.items[130])
            let selected = viewModel.selectedID

            for index in 0..<Constants.List.pageSize {
                // The dates run backward. The store still lists each copy above the one before it.
                let date = Date(timeIntervalSince1970: 1_700_000_000 - TimeInterval(index))
                _ = try await store.insert(Fixtures.textCapture("row page \(text.count) \(index)"), at: date)
            }
            viewModel.historyDidChange()
            await waitUntil { self.viewModel.items.count == 200 + Constants.List.pageSize }
            try await settle()

            let rows = viewModel.items
            let expected = text.isEmpty ? try await allIDs(limit: rows.count) : try await searchIDs(text, limit: rows.count)
            XCTAssertEqual(rows.map(\.id), expected, text.isEmpty ? "the history" : "the search")
            XCTAssertEqual(Array(rows.map(\.id).suffix(200)), loaded, "the loaded rows stay below the page")
            XCTAssertEqual(rows[0].title, "row page \(text.count) \(Constants.List.pageSize - 1)")
            XCTAssertEqual(viewModel.selectedID, selected)
            XCTAssertEqual(viewModel.selectedIndex, 130 + Constants.List.pageSize)
            viewModel.panelDidHide()
        }
    }

    /// The fresh page's last row was loaded lower down before it was copied again. Its old position
    /// provides no ordering information, so all loaded rows absent from the page come after the
    /// page.
    func testAWholePageOfRepeatCopiesMovesAboveTheRowsThatStayed() async throws {
        for text in ["", "row"] {
            if text.isEmpty {
                await showFirstPage()
                await loadPages(2)
            } else {
                try await showSearch(text, pages: 2)
            }
            let loaded = viewModel.items
            let moved = Array(loaded[100..<200])
            viewModel.select(loaded[40])
            let selected = viewModel.selectedID

            for item in moved {
                try await store.touch(id: item.id, at: Date(timeIntervalSince1970: 1_700_000_000))
            }
            viewModel.historyDidChange()
            await waitUntil { self.viewModel.items.first?.id == moved.last?.id }
            try await settle()
            try await settle()

            let rows = viewModel.items
            let expected = text.isEmpty ? try await allIDs(limit: rows.count) : try await searchIDs(text, limit: rows.count)
            XCTAssertEqual(rows.map(\.id), expected, text.isEmpty ? "the history" : "the search")
            XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "a moved row is listed once")
            XCTAssertEqual(rows.count, 200)
            XCTAssertEqual(rows.prefix(Constants.List.pageSize).map(\.id), moved.reversed().map(\.id))
            XCTAssertEqual(Array(rows.suffix(100)), Array(loaded.prefix(100)), "the rows that stayed keep their order")
            XCTAssertTrue(datesFallInOrder(rows))
            XCTAssertEqual(viewModel.selectedID, selected)
            XCTAssertEqual(viewModel.selectedIndex, 140)
            viewModel.panelDidHide()
        }
    }
}

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
}

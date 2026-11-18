import AppKit
import XCTest
@testable import ClipDeck

@MainActor
final class MenuBarControllerTests: XCTestCase {
    private var directory: URL!
    private var store: ClipStore!

    override func setUp() async throws {
        directory = Fixtures.temporaryDirectory()
        store = try ClipStore(location: StoreLocation(root: directory))
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// The controller has no status item, so the tests never draw in the menu bar.
    private func controller(fetchRecent: (@MainActor () async throws -> [ClipItem])? = nil) -> MenuBarController {
        MenuBarController(
            store: store,
            actions: .init(openPanel: {}, copy: { _ in }, clearHistory: {}, openSettings: {}),
            updater: nil,
            statusBar: nil,
            fetchRecent: fetchRecent
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition not met in time", file: file, line: line)
    }

    private func rows(of menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { $0.representedObject is Int64 }
    }

    func testTheMenuListsTheTenMostRecentItems() async throws {
        for index in 0..<14 {
            _ = try await store.insert(Fixtures.textCapture("item \(index)"), at: Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(index)))
        }
        let controller = controller()
        await waitUntil { controller.recent.count == Constants.Menu.recentCount }

        controller.menuNeedsUpdate(controller.menu)
        let rows = rows(of: controller.menu)
        XCTAssertEqual(rows.map(\.title), (4..<14).reversed().map { "item \($0)" })
        XCTAssertEqual(rows.map(\.keyEquivalent), Constants.Menu.rowKeys)
    }

    func testAnEmptyHistoryShowsNoRows() async {
        let controller = controller()
        controller.menuNeedsUpdate(controller.menu)
        XCTAssertTrue(rows(of: controller.menu).isEmpty)
    }

    func testOpeningTheMenuAgainReusesTheRowIcons() async throws {
        _ = try await store.insert(Fixtures.textCapture("text"), at: Date(timeIntervalSince1970: 1_800_000_000))
        _ = try await store.insert(Fixtures.fileCapture(["/tmp/report.pdf"]), at: Date(timeIntervalSince1970: 1_800_000_001))
        let controller = controller()
        await waitUntil { controller.recent.count == 2 }

        controller.menuNeedsUpdate(controller.menu)
        let first = rows(of: controller.menu).map(\.image)
        controller.menuNeedsUpdate(controller.menu)
        let second = rows(of: controller.menu).map(\.image)

        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(first.allSatisfy { $0 != nil })
        XCTAssertTrue(zip(first, second).allSatisfy { $0 === $1 })
        controller.menuDidClose(controller.menu)
    }

    func testAClearedImageLeavesNoIconBehind() async throws {
        let capture = Fixtures.imageCapture(width: 400, height: 300)
        _ = try await store.insert(capture, at: Date(timeIntervalSince1970: 1_800_000_000))
        await ThumbnailGenerator(store: store).generate(for: capture)
        let controller = controller()
        await waitUntil { controller.recent.count == 1 }

        controller.menuNeedsUpdate(controller.menu)
        let placeholder = try XCTUnwrap(rows(of: controller.menu).first?.image)
        await waitUntil { self.rows(of: controller.menu).first?.image !== placeholder }
        let thumbnail = try XCTUnwrap(rows(of: controller.menu).first?.image)
        controller.menuDidClose(controller.menu)
        controller.menuNeedsUpdate(controller.menu)
        XCTAssertTrue(rows(of: controller.menu).first?.image === thumbnail, "the icon is kept between openings")
        controller.menuDidClose(controller.menu)

        // The Clear History window does the following.
        _ = try await store.clear(ClearRequest(range: .allTime, kinds: Set(ClipKind.allCases)))
        ThumbnailCache.shared.removeAll()
        NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
        await waitUntil { controller.recent.isEmpty }
        XCTAssertNil(ThumbnailCache.shared.cachedImage(for: capture.hash, maxPixelSize: Constants.Menu.iconPixelSize))

        // The same image copied again has no thumbnail yet, so nothing may draw the old one.
        _ = try await store.insert(capture, at: Date(timeIntervalSince1970: 1_800_000_001))
        NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
        await waitUntil { controller.recent.count == 1 }
        controller.menuNeedsUpdate(controller.menu)
        let shown = rows(of: controller.menu).first?.image
        XCTAssertFalse(shown === thumbnail)
        XCTAssertTrue(shown === placeholder)
        controller.menuDidClose(controller.menu)
    }

    func testABurstOfHistoryChangesSharesItsReads() async throws {
        _ = try await store.insert(Fixtures.textCapture("first"), at: Date(timeIntervalSince1970: 1_800_000_000))
        let reads = ReadCounter()
        let store = self.store!
        let controller = controller {
            reads.increment()
            return try await store.page(limit: Constants.Menu.recentCount)
        }
        await waitUntil { controller.recent.count == 1 }
        let before = reads.count

        _ = try await store.insert(Fixtures.textCapture("second"), at: Date(timeIntervalSince1970: 1_800_000_001))
        for _ in 0..<40 {
            NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
        }
        await waitUntil { controller.recent.first?.title == "second" }
        for _ in 0..<3 {
            for _ in 0..<5 { await Task.yield() }
            _ = try await store.count()
        }
        XCTAssertLessThanOrEqual(reads.count - before, 2)
        XCTAssertGreaterThanOrEqual(reads.count - before, 1)
    }

    func testAFailedReadKeepsTheRowsAndTheNextChangeRefreshes() async throws {
        _ = try await store.insert(Fixtures.textCapture("first"), at: Date(timeIntervalSince1970: 1_800_000_000))
        let reads = ReadCounter()
        let store = self.store!
        let controller = controller {
            if reads.increment() == 2 { throw CocoaError(.fileReadUnknown) }
            return try await store.page(limit: Constants.Menu.recentCount)
        }
        await waitUntil { controller.recent.count == 1 }

        _ = try await store.insert(Fixtures.textCapture("second"), at: Date(timeIntervalSince1970: 1_800_000_001))
        NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
        await waitUntil { reads.count == 2 }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(controller.recent.map(\.title), ["first"])

        NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
        await waitUntil { controller.recent.first?.title == "second" }
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return reads
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }
}

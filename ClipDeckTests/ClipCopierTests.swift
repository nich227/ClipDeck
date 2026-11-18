import AppKit
import XCTest
@testable import ClipDeck

@MainActor
final class ClipCopierTests: XCTestCase {
    private var directory: URL!
    private var store: ClipStore!
    private var pasteboard: NSPasteboard!
    private var monitor: PasteboardMonitor!
    private var copier: ClipCopier!

    override func setUp() async throws {
        directory = Fixtures.temporaryDirectory()
        store = try ClipStore(location: StoreLocation(root: directory))
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipDeckTests-\(UUID().uuidString)"))
        monitor = PasteboardMonitor(pasteboard: pasteboard) { _ in }
        copier = ClipCopier(store: store, monitor: monitor)
    }

    override func tearDown() async throws {
        copier = nil
        monitor = nil
        pasteboard.releaseGlobally()
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func newest() async throws -> ClipItem? {
        try await store.page().first
    }

    private func insert(_ capture: Capture, at seconds: TimeInterval) async throws {
        _ = try await store.insert(capture, at: Date(timeIntervalSince1970: seconds))
    }

    func testCopyWritesTheItemAndMovesItToTheTop() async throws {
        try await insert(Fixtures.textCapture("older"), at: 1_700_000_000)
        try await insert(Fixtures.textCapture("newer"), at: 1_700_000_001)
        let rows = try await store.page()
        let older = try XCTUnwrap(rows.last)

        let copied = await copier.copy(older)
        XCTAssertTrue(copied)
        XCTAssertEqual(pasteboard.string(forType: .string), "older")
        let first = try await store.page().first
        XCTAssertEqual(first?.id, older.id)
    }

    func testTheConfirmationComesBeforeTheHistoryChange() async throws {
        try await insert(Fixtures.textCapture("item"), at: 1_700_000_000)
        let row = try await newest()
        let item = try XCTUnwrap(row)

        var events: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: .clipHistoryDidChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { events.append("history") }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        copier.onCopied = { copied in events.append("confirmed \(copied.id)") }

        let copied = await copier.copy(item)
        XCTAssertTrue(copied)
        XCTAssertEqual(events, ["confirmed \(item.id)", "history"])
    }

    func testCopyingFilesWritesEveryURLInOrder() async throws {
        let urls = try (0..<40).map { index -> URL in
            let url = directory.appendingPathComponent("copied \(index).txt")
            try Data("x".utf8).write(to: url)
            return url
        }
        let classified = PasteboardClassifier().classify(Fixtures.snapshot(urls.map { [PasteboardTypes.fileURL: $0.dataRepresentation] }))
        guard case .capture(let capture) = classified else { return XCTFail("files did not classify") }
        try await insert(capture, at: 1_700_000_000)
        let row = try await newest()
        let item = try XCTUnwrap(row)

        let copied = await copier.copy(item)
        XCTAssertTrue(copied)
        let written = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        XCTAssertEqual(written?.map { $0.resolvingSymlinksInPath().path }, urls.map { $0.resolvingSymlinksInPath().path })
    }

    func testCopyingAnImageWritesItsBytes() async throws {
        let capture = Fixtures.imageCapture(width: 16, height: 12)
        try await insert(capture, at: 1_700_000_000)
        let row = try await newest()
        let item = try XCTUnwrap(row)

        let copied = await copier.copy(item)
        XCTAssertTrue(copied)
        XCTAssertEqual(pasteboard.data(forType: .png), capture.blob?.data)
    }

    func testAnItemThatLeftTheStoreCopiesNothing() async throws {
        try await insert(Fixtures.textCapture("cleared"), at: 1_700_000_000)
        let row = try await newest()
        let item = try XCTUnwrap(row)
        _ = try await store.clear(ClearRequest(range: .allTime, kinds: [.text]))
        pasteboard.clearContents()
        pasteboard.setString("untouched", forType: .string)
        var confirmed = false
        var failures = 0
        copier.onCopied = { _ in confirmed = true }
        copier.onFailed = { failures += 1 }

        let copied = await copier.copy(item)
        XCTAssertFalse(copied)
        XCTAssertFalse(confirmed)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
    }

    func testAnImageThatLostItsFileFailsTheSameWay() async throws {
        let capture = Fixtures.imageCapture(width: 16, height: 12)
        try await insert(capture, at: 1_700_000_000)
        let row = try await newest()
        let item = try XCTUnwrap(row)
        try FileManager.default.removeItem(at: store.location.blobURL(for: capture.hash))
        pasteboard.clearContents()
        pasteboard.setString("untouched", forType: .string)
        var confirmed = false
        var failures = 0
        copier.onCopied = { _ in confirmed = true }
        copier.onFailed = { failures += 1 }

        let copied = await copier.copy(item)
        XCTAssertFalse(copied)
        XCTAssertFalse(confirmed)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
    }

    func testAnItemThatCannotBeWrittenReportsTheFailure() async throws {
        // A file item writes nothing when there is no file to name.
        let empty = Capture(
            kind: .file, hash: "no-files", title: "Nothing", detail: nil, searchText: "Nothing", byteSize: 0,
            representations: [], offersPlainText: false, files: [], blob: nil, offersTIFF: false
        )
        try await insert(empty, at: 1_700_000_000)
        let row = try await newest()
        let item = try XCTUnwrap(row)
        pasteboard.clearContents()
        pasteboard.setString("untouched", forType: .string)
        var confirmed = false
        var failures = 0
        copier.onCopied = { _ in confirmed = true }
        copier.onFailed = { failures += 1 }

        let copied = await copier.copy(item)
        XCTAssertFalse(copied)
        XCTAssertFalse(confirmed, "no confirmation for a copy that did not happen")
        XCTAssertEqual(failures, 1, "a copy that fails at the pasteboard is not silent")
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
    }

    func testAFailedCopyTellsTheListsToReadTheHistoryAgain() async throws {
        try await insert(Fixtures.textCapture("cleared"), at: 1_700_000_000)
        let row = try await newest()
        let item = try XCTUnwrap(row)
        _ = try await store.clear(ClearRequest(range: .allTime, kinds: [.text]))
        var events: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: .clipHistoryDidChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { events.append("history") }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        copier.onFailed = { events.append("failed") }

        let copied = await copier.copy(item)
        XCTAssertFalse(copied)
        XCTAssertEqual(events, ["failed", "history"])
    }
}

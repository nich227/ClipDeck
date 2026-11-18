import AppKit
import os
import XCTest
@testable import ClipDeck

@MainActor
final class ThumbnailTests: XCTestCase {
    private var directory: URL!
    private var store: ClipStore!
    private var generator: ThumbnailGenerator!

    override func setUp() async throws {
        directory = Fixtures.temporaryDirectory()
        store = try ClipStore(location: StoreLocation(root: directory))
        generator = ThumbnailGenerator(store: store)
    }

    override func tearDown() async throws {
        generator = nil
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func storedImage(width: Int = 1_200, height: Int = 900) async throws -> Capture {
        let capture = Fixtures.imageCapture(width: width, height: height)
        _ = try await store.insert(capture)
        return capture
    }

    // MARK: - Generator

    func testRequestsForOneHashAtTheSameTimeSaveOneThumbnail() async throws {
        let capture = try await storedImage()
        let generator = self.generator!
        let saved = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<8 {
                group.addTask { await generator.generate(for: capture) }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        XCTAssertEqual(saved, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.location.thumbnailURL(for: capture.hash).path))
    }

    func testAnExistingThumbnailAndTextAreSkipped() async throws {
        let capture = try await storedImage(width: 40, height: 30)
        let first = await generator.generate(for: capture)
        let second = await generator.generate(for: capture)
        let text = await generator.generate(for: Fixtures.textCapture("no thumbnail"))
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertFalse(text)
    }

    func testAThumbnailThatCouldNotBeSavedCanBeMadeLater() async throws {
        let capture = Fixtures.imageCapture(width: 40, height: 30)
        let withoutARow = await generator.generate(for: capture)
        XCTAssertFalse(withoutARow, "the blob is not on disk before the item is stored")

        _ = try await store.insert(capture)
        let afterInsert = await generator.generate(for: capture)
        XCTAssertTrue(afterInsert)
    }

    func testAThumbnailWhoseItemIsGoneIsNotSavedAndLeavesNoFile() async throws {
        // The image file exists, but no row names it, as happens while a row is being removed.
        let capture = Fixtures.imageCapture(width: 40, height: 30)
        try XCTUnwrap(capture.blob).data.write(to: store.location.blobURL(for: capture.hash))

        let saved = await generator.generate(for: capture)
        XCTAssertFalse(saved, "nothing announces a thumbnail that was not saved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location.thumbnailURL(for: capture.hash).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.location.thumbs.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.location.staging.path), [])

        let again = await generator.generate(for: capture)
        XCTAssertFalse(again, "a later request starts over instead of waiting on the first")
    }

    func testASavedThumbnailIsAWholeFileAtThePathTheListsRead() async throws {
        let capture = try await storedImage(width: 400, height: 300)
        let saved = await generator.generate(for: capture)
        XCTAssertTrue(saved)
        let url = store.location.thumbnailURL(for: capture.hash)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.location.thumbs.path), [url.lastPathComponent])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.location.staging.path), [])
        XCTAssertNotNil(ImageProcessing.thumbnail(from: url, maxPixelSize: Constants.Panel.rowThumbnailPixelSize))
    }

    // MARK: - Cache

    func testRequestsForOneHashAtTheSameTimeShareOneImage() async throws {
        let capture = try await storedImage(width: 400, height: 300)
        await generator.generate(for: capture)
        let cache = ThumbnailCache()
        let url = store.location.thumbnailURL(for: capture.hash)

        let images = await withTaskGroup(of: NSImage?.self) { group -> [NSImage?] in
            for _ in 0..<8 {
                group.addTask { @MainActor in await cache.image(for: capture.hash, at: url) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let first = try XCTUnwrap(images.first ?? nil)
        XCTAssertEqual(images.count, 8)
        XCTAssertTrue(images.allSatisfy { $0 === first })
        // The system may empty the cache at any time, so the cache contains either the same image
        // or no image.
        let kept = cache.cachedImage(for: capture.hash)
        XCTAssertTrue(kept == nil || kept === first)
    }

    func testTheCachedImageIsADecodedBitmapOfTheThumbnail() async throws {
        let capture = try await storedImage(width: 400, height: 300)
        await generator.generate(for: capture)
        let cache = ThumbnailCache()
        let loaded = await cache.image(for: capture.hash, at: store.location.thumbnailURL(for: capture.hash))
        let image = try XCTUnwrap(loaded)
        XCTAssertEqual(image.size, NSSize(width: 400, height: 300))
        var rect = NSRect(origin: .zero, size: image.size)
        let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        XCTAssertEqual(bitmap.width, 400)
        XCTAssertEqual(bitmap.height, 300)
    }

    func testASmallerSizeIsDecodedOnItsOwn() async throws {
        let capture = try await storedImage(width: 400, height: 300)
        await generator.generate(for: capture)
        let cache = ThumbnailCache()
        let url = store.location.thumbnailURL(for: capture.hash)

        let small = await cache.image(for: capture.hash, at: url, maxPixelSize: 100)
        let full = await cache.image(for: capture.hash, at: url)
        XCTAssertEqual(small?.size, NSSize(width: 100, height: 75))
        XCTAssertEqual(full?.size, NSSize(width: 400, height: 300))
        // The system may empty the cache at any time, so the cache contains either the correct
        // image or no image.
        let keptSmall = cache.cachedImage(for: capture.hash, maxPixelSize: 100)
        let keptFull = cache.cachedImage(for: capture.hash)
        XCTAssertTrue(keptSmall == nil || keptSmall === small)
        XCTAssertTrue(keptFull == nil || keptFull === full)
    }

    func testAMissingThumbnailIsNotCachedSoALaterRequestFindsIt() async throws {
        let capture = try await storedImage(width: 40, height: 30)
        let cache = ThumbnailCache()
        let url = store.location.thumbnailURL(for: capture.hash)

        let before = await cache.image(for: capture.hash, at: url)
        XCTAssertNil(before)
        XCTAssertNil(cache.cachedImage(for: capture.hash))

        await generator.generate(for: capture)
        let after = await cache.image(for: capture.hash, at: url)
        XCTAssertNotNil(after)
    }

    func testEmptyingTheCacheForgetsEveryImage() async throws {
        let capture = try await storedImage(width: 40, height: 30)
        await generator.generate(for: capture)
        let cache = ThumbnailCache()
        let url = store.location.thumbnailURL(for: capture.hash)
        let loaded = await cache.image(for: capture.hash, at: url)
        XCTAssertNotNil(loaded)

        cache.removeAll()
        XCTAssertNil(cache.cachedImage(for: capture.hash))
    }

    func testEmptyingTheCacheForgetsTheRowSizeToo() async throws {
        let capture = try await storedImage(width: 400, height: 300)
        await generator.generate(for: capture)
        let cache = ThumbnailCache()
        let url = store.location.thumbnailURL(for: capture.hash)
        let row = Constants.Panel.rowThumbnailPixelSize
        XCTAssertEqual(row, Constants.Menu.iconPixelSize, "a row and a menu item share one cached bitmap")
        let small = await cache.image(for: capture.hash, at: url, maxPixelSize: row)
        let full = await cache.image(for: capture.hash, at: url)
        XCTAssertNotNil(small)
        XCTAssertNotNil(full)

        cache.removeAll()
        XCTAssertNil(cache.cachedImage(for: capture.hash, maxPixelSize: row))
        XCTAssertNil(cache.cachedImage(for: capture.hash))
    }

    func testAnImageOverTheCostLimitIsReturnedButNotKept() async throws {
        let capture = try await storedImage(width: 400, height: 300)
        await generator.generate(for: capture)
        let cache = ThumbnailCache(costLimit: 1_024)
        let loaded = await cache.image(for: capture.hash, at: store.location.thumbnailURL(for: capture.hash))
        XCTAssertNotNil(loaded)
        XCTAssertNil(cache.cachedImage(for: capture.hash))
    }

    // MARK: - Ingest

    func testIngestAnnouncesTheInsertThenTheThumbnail() async throws {
        let events = EventLog()
        let center = NotificationCenter.default
        let tokens = [
            center.addObserver(forName: .clipHistoryDidChange, object: nil, queue: nil) { _ in events.append("history") },
            center.addObserver(forName: .clipThumbnailDidChange, object: nil, queue: nil) { note in
                events.append("thumbnail:\(note.object as? String ?? "")")
            },
        ]
        defer { tokens.forEach(center.removeObserver) }

        let image = Fixtures.imageCapture(width: 40, height: 30)
        await AppDelegate.ingest(image, store: store, thumbnails: generator)
        XCTAssertEqual(events.all, ["history", "thumbnail:\(image.hash)", "history"])

        await AppDelegate.ingest(image, store: store, thumbnails: generator)
        XCTAssertEqual(events.all.count, 4, "a repeat copy with a thumbnail announces only the bump")

        await AppDelegate.ingest(Fixtures.textCapture("plain"), store: store, thumbnails: generator)
        XCTAssertEqual(events.all.suffix(1), ["history"])
        XCTAssertEqual(events.all.count, 5)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition not met in time", file: file, line: line)
    }

    /// The app wires both the panel and the menu to follow the history change.
    func testACapturedImageReachesTheOpenPanelAndCostsEachListTwoReadsAtMost() async throws {
        _ = try await store.insert(Fixtures.textCapture("already here"))
        let store = self.store!
        let recorder = FetchRecorder(store: store)
        let viewModel = HistoryViewModel(store: store, fetch: recorder.fetch)
        let menuReads = OSAllocatedUnfairLock(initialState: 0)
        let menu = MenuBarController(
            store: store, actions: .init(openPanel: {}, copy: { _ in }, clearHistory: {}, openSettings: {}),
            updater: nil, statusBar: nil
        ) {
            menuReads.withLock { $0 += 1 }
            return try await store.page(limit: Constants.Menu.recentCount)
        }
        let forward = NotificationCenter.default.addObserver(forName: .clipHistoryDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { viewModel.historyDidChange() }
        }
        defer { NotificationCenter.default.removeObserver(forward) }
        viewModel.panelWillShow()
        await waitUntil { viewModel.items.count == 1 && menu.recent.count == 1 }
        recorder.reset()
        menuReads.withLock { $0 = 0 }
        let token = viewModel.refreshToken

        let image = Fixtures.imageCapture(width: 400, height: 300)
        await AppDelegate.ingest(image, store: store, thumbnails: generator)
        await waitUntil { viewModel.items.first?.hash == image.hash && menu.recent.first?.hash == image.hash }
        for _ in 0..<3 {
            for _ in 0..<5 { await Task.yield() }
            _ = try await store.count()
        }

        XCTAssertEqual(viewModel.refreshToken, token + 1, "the saved thumbnail restarts the rows' loads once")
        XCTAssertLessThanOrEqual(recorder.firstPageReads, 2)
        XCTAssertLessThanOrEqual(menuReads.withLock { $0 }, 2)
        let url = store.location.thumbnailURL(for: image.hash)
        let row = await ThumbnailCache().image(for: image.hash, at: url, maxPixelSize: Constants.Panel.rowThumbnailPixelSize)
        let preview = await ThumbnailCache().image(for: image.hash, at: url)
        XCTAssertNotNil(row, "the row's load after the token changed finds the file")
        XCTAssertNotNil(preview)
    }

    /// Settings reads the usage figure on each history change.
    func testTheHistoryChangeAfterAThumbnailFollowsItsBytes() async throws {
        let store = self.store!
        let usages = OSAllocatedUnfairLock(initialState: [Int64]())
        let observer = NotificationCenter.default.addObserver(forName: .clipHistoryDidChange, object: nil, queue: nil) { _ in
            Task {
                guard let usage = try? await store.storageUsage() else { return }
                usages.withLock { $0.append(usage) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let image = Fixtures.imageCapture(width: 400, height: 300)
        await AppDelegate.ingest(image, store: store, thumbnails: generator)
        await waitUntil { usages.withLock { $0.count } == 2 }

        let thumbnail = try FileManager.default.attributesOfItem(atPath: store.location.thumbnailURL(for: image.hash).path)[.size] as? Int64
        let expected = image.byteSize + (try XCTUnwrap(thumbnail))
        XCTAssertEqual(usages.withLock { $0.max() }, expected)
        let final = try await store.storageUsage()
        XCTAssertEqual(final, expected)
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

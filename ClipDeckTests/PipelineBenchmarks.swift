import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ClipDeck

/// Measures the capture, thumbnail, list, copy, and menu paths. These benchmarks run only when
/// `CLIPDECK_BENCH=1` is set. xcodebuild forwards it from `TEST_RUNNER_CLIPDECK_BENCH=1`. Every
/// pasteboard is private and named. Every store lives in a temporary directory.
@MainActor
final class PipelineBenchmarks: XCTestCase {
    private var directory: URL!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLIPDECK_BENCH"] == "1", "Set CLIPDECK_BENCH=1 to run benchmarks")
        directory = Fixtures.temporaryDirectory()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipDeckBench-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard?.releaseGlobally()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Capture

    func testClassifySmallText() {
        let snapshot = Fixtures.snapshot([[PasteboardTypes.plainText: Data("a short line of text".utf8)]])
        Bench.report("classify text 20 B", iterations: 2000) { _ = PasteboardClassifier().classify(snapshot) }
    }

    func testClassifyLargeText() {
        let data = Data(BenchFixtures.text(megabytes: 5).utf8)
        let snapshot = Fixtures.snapshot([[PasteboardTypes.plainText: data]])
        Bench.report("classify text 5 MB", iterations: 8) { _ = PasteboardClassifier().classify(snapshot) }
    }

    func testClassifyLargeTextWithBlankLeadingLines() {
        let text = String(repeating: "\n", count: 1_000) + BenchFixtures.text(megabytes: 5)
        let snapshot = Fixtures.snapshot([[PasteboardTypes.plainText: Data(text.utf8)]])
        Bench.report("classify text 5 MB after 1000 blank lines", iterations: 8) { _ = PasteboardClassifier().classify(snapshot) }
    }

    func testClassifyRichText() {
        let plain = BenchFixtures.text(megabytes: 1).prefix(50_000)
        let snapshot = Fixtures.snapshot([[
            PasteboardTypes.plainText: Data(plain.utf8),
            PasteboardTypes.rtf: Data("{\\rtf1 \(plain)}".utf8),
            PasteboardTypes.html: Data("<p>\(plain)</p>".utf8),
            "com.apple.webarchive": Data(count: 200_000),
            "org.chromium.web-custom-data": Data(count: 20_000),
        ]])
        Bench.report("classify rich text 5 types 370 KB", iterations: 200) { _ = PasteboardClassifier().classify(snapshot) }
    }

    func testClassifyLargeImages() {
        let png = BenchFixtures.png
        let tiff = BenchFixtures.tiff
        print("BENCH fixture image \(BenchFixtures.width)x\(BenchFixtures.height): png \(png.count) B, tiff \(tiff.count) B")
        let both = Fixtures.snapshot([[PasteboardTypes.png: png, PasteboardTypes.tiff: tiff]])
        Bench.report("classify image PNG+TIFF \(png.count / 1_000_000) MB", iterations: 10) { _ = PasteboardClassifier().classify(both) }
        let tiffOnly = Fixtures.snapshot([[PasteboardTypes.tiff: tiff]])
        Bench.report("classify image TIFF only \(tiff.count / 1_000_000) MB", iterations: 3) { _ = PasteboardClassifier().classify(tiffOnly) }
    }

    func testClassifyFiveHundredFiles() throws {
        let urls = try BenchFixtures.files(count: 500, in: directory)
        let snapshot = Fixtures.snapshot(urls.map { [PasteboardTypes.fileURL: $0.dataRepresentation] })
        Bench.report("classify 500 files, real bookmarks and sizes", iterations: 5) { _ = PasteboardClassifier().classify(snapshot) }
        Bench.report("classify 500 files, stub bookmarks and sizes", iterations: 20) { _ = Fixtures.classifier().classify(snapshot) }
    }

    func testReadAndClassifyFromAPasteboard() {
        let text = BenchFixtures.text(megabytes: 5)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let pasteboard = self.pasteboard!
        Bench.report("pasteboard read + classify text 5 MB", iterations: 8) {
            _ = PasteboardClassifier().classify(PasteboardSnapshot.read(from: pasteboard))
        }
    }

    func testReadAndClassifyFilesFromAPasteboard() throws {
        let urls = try BenchFixtures.files(count: 500, in: directory)
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        })
        let pasteboard = self.pasteboard!
        Bench.report("pasteboard read + classify 500 files, stub bookmarks", iterations: 10) {
            _ = Fixtures.classifier().classify(PasteboardSnapshot.read(from: pasteboard))
        }
    }

    func testReadAndClassifyAnImageFromAPasteboard() {
        pasteboard.clearContents()
        pasteboard.setData(BenchFixtures.png, forType: .png)
        let pasteboard = self.pasteboard!
        Bench.report("pasteboard read + classify image PNG", iterations: 10) {
            _ = PasteboardClassifier().classify(PasteboardSnapshot.read(from: pasteboard))
        }
    }

    func testIdlePollReadsOneInteger() {
        let pasteboard = self.pasteboard!
        var sum = 0
        Bench.report("changeCount read x1000", iterations: 50) {
            for _ in 0..<1_000 { sum &+= pasteboard.changeCount }
        }
        XCTAssertGreaterThanOrEqual(sum, 0)
    }

    // MARK: - Thumbnails

    func testThumbnailGeneration() async throws {
        let store = try ClipStore(location: StoreLocation(root: directory))
        let generator = ThumbnailGenerator(store: store)
        var samples: [Duration] = []
        for index in 0..<5 {
            let png = BenchFixtures.pngVariant(index)
            guard case .capture(let capture) = PasteboardClassifier().classify(Fixtures.snapshot([[PasteboardTypes.png: png]])) else {
                return XCTFail("image did not classify")
            }
            _ = try await store.insert(capture)
            let start = ContinuousClock.now
            let saved = await generator.generate(for: capture)
            samples.append(ContinuousClock.now - start)
            XCTAssertTrue(saved)
        }
        Bench.print("thumbnail generate from \(BenchFixtures.width)x\(BenchFixtures.height) PNG", samples)

        let capture = Fixtures.imageCapture(width: 64, height: 64)
        _ = try await store.insert(capture)
        _ = await generator.generate(for: capture)
        var skips: [Duration] = []
        for _ in 0..<200 {
            let start = ContinuousClock.now
            _ = await generator.generate(for: capture)
            skips.append(ContinuousClock.now - start)
        }
        Bench.print("thumbnail generate when one exists", skips)
    }

    func testThumbnailCache() async throws {
        let store = try ClipStore(location: StoreLocation(root: directory))
        let generator = ThumbnailGenerator(store: store)
        var hashes: [String] = []
        for index in 0..<12 {
            let png = BenchFixtures.pngVariant(index)
            guard case .capture(let capture) = PasteboardClassifier().classify(Fixtures.snapshot([[PasteboardTypes.png: png]])) else {
                return XCTFail("image did not classify")
            }
            _ = try await store.insert(capture)
            _ = await generator.generate(for: capture)
            hashes.append(capture.hash)
        }

        let cache = ThumbnailCache()
        var misses: [Duration] = []
        var draws: [Duration] = []
        for hash in hashes {
            let start = ContinuousClock.now
            let image = await cache.image(for: hash, at: store.location.thumbnailURL(for: hash))
            misses.append(ContinuousClock.now - start)
            let unwrapped = try XCTUnwrap(image)
            let drawStart = ContinuousClock.now
            BenchFixtures.draw(unwrapped, side: 64)
            draws.append(ContinuousClock.now - drawStart)
        }
        Bench.print("thumbnail cache miss (await, 512 px PNG)", misses)
        Bench.print("first draw on the main thread after a miss", draws)

        var hits: [Duration] = []
        for _ in 0..<50 {
            for hash in hashes {
                let start = ContinuousClock.now
                _ = cache.cachedImage(for: hash)
                hits.append(ContinuousClock.now - start)
            }
        }
        Bench.print("thumbnail cache hit", hits)

        let concurrent = ThumbnailCache()
        let hash = hashes[0]
        let url = store.location.thumbnailURL(for: hash)
        let start = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { @MainActor in _ = await concurrent.image(for: hash, at: url) }
            }
        }
        Bench.print("8 concurrent requests for one hash", [ContinuousClock.now - start])
    }

    // MARK: - List

    func testReloadAndPaging() async throws {
        let store = try ClipStore(location: StoreLocation(root: directory))
        try await BenchFixtures.fill(store, rows: 5_000)
        let viewModel = HistoryViewModel(store: store)
        viewModel.panelWillShow()
        await BenchFixtures.spin { viewModel.items.count == Constants.List.pageSize }

        var next = 5_000
        func captureAndWait() async throws -> Duration {
            let title = "fresh \(next)"
            next += 1
            _ = try await store.insert(Fixtures.textCapture(title))
            let start = ContinuousClock.now
            viewModel.historyDidChange()
            await BenchFixtures.spin { viewModel.items.first?.title == title }
            return ContinuousClock.now - start
        }

        var publishes = 0
        let subscription = viewModel.objectWillChange.sink { publishes += 1 }
        defer { subscription.cancel() }

        var atOnePage: [Duration] = []
        for _ in 0..<30 { atOnePage.append(try await captureAndWait()) }
        Bench.print("reload after a capture, 100 rows loaded", atOnePage)
        try await BenchFixtures.settle(store)
        print("BENCH publishes for 30 captures with the panel open: \(publishes)")

        publishes = 0
        for _ in 0..<30 {
            viewModel.historyDidChange()
            try await BenchFixtures.settle(store)
        }
        print("BENCH publishes for 30 history changes that change no row: \(publishes)")
        subscription.cancel()

        var pageTimes: [Duration] = []
        while viewModel.items.count < 3_000 {
            let count = viewModel.items.count
            let start = ContinuousClock.now
            viewModel.loadMoreIfNeeded(after: viewModel.items[count - 1])
            await BenchFixtures.spin { viewModel.items.count > count }
            pageTimes.append(ContinuousClock.now - start)
        }
        Bench.print("loadMore one page, growing 100 to 3000 rows", pageTimes)
        Bench.print("loadMore one page, last five near 3000 rows", Array(pageTimes.suffix(5)))

        let loaded = viewModel.items.count
        let deep = try await captureAndWait()
        Bench.print("reload after a capture, \(loaded) rows loaded", [deep])
        print("BENCH rows loaded after that reload: \(viewModel.items.count)")

        while viewModel.items.count < 3_000 {
            let count = viewModel.items.count
            viewModel.loadMoreIfNeeded(after: viewModel.items[count - 1])
            await BenchFixtures.spin { viewModel.items.count > count }
        }
        var moves: [Duration] = []
        for round in 0..<20 {
            let start = ContinuousClock.now
            for _ in 0..<100 { viewModel.moveSelection(by: round.isMultiple(of: 2) ? 1 : -1) }
            moves.append(ContinuousClock.now - start)
        }
        Bench.print("moveSelection x100, \(viewModel.items.count) rows loaded", moves)

        var selects: [Duration] = []
        let targets = Array(viewModel.items[1_000..<1_100])
        for _ in 0..<20 {
            let start = ContinuousClock.now
            for item in targets {
                viewModel.select(item)
                _ = viewModel.selectedItem
            }
            selects.append(ContinuousClock.now - start)
        }
        Bench.print("select + selectedItem x100, \(viewModel.items.count) rows loaded", selects)
    }

    func testBurstOfHistoryChanges() async throws {
        let store = try ClipStore(location: StoreLocation(root: directory))
        try await BenchFixtures.fill(store, rows: 5_000)
        let viewModel = HistoryViewModel(store: store)
        viewModel.panelWillShow()
        await BenchFixtures.spin { viewModel.items.count == Constants.List.pageSize }

        var samples: [Duration] = []
        var tokens: [Int] = []
        for _ in 0..<10 {
            let before = viewModel.refreshToken
            let start = ContinuousClock.now
            for _ in 0..<50 { viewModel.historyDidChange() }
            // The reload tasks need one turn to queue their reads. The count then waits behind
            // every queued read. One more turn lets the results apply.
            for _ in 0..<4 { await Task.yield() }
            _ = try await store.count()
            for _ in 0..<4 { await Task.yield() }
            _ = try await store.count()
            for _ in 0..<4 { await Task.yield() }
            samples.append(ContinuousClock.now - start)
            tokens.append(viewModel.refreshToken - before)
        }
        Bench.print("50 history changes at once until settled", samples)
        print("BENCH refreshToken bumps per burst of 50: \(tokens)")
    }

    // MARK: - Copy

    func testCopyEndToEnd() async throws {
        let store = try ClipStore(location: StoreLocation(root: directory))
        let monitor = PasteboardMonitor(pasteboard: pasteboard) { _ in }
        let copier = ClipCopier(store: store, monitor: monitor)

        _ = try await store.insert(Fixtures.textCapture("a short line of text"))
        let largeText = BenchFixtures.text(megabytes: 5)
        _ = try await store.insert(Fixtures.textCapture(largeText))
        guard case .capture(let image) = PasteboardClassifier().classify(
            Fixtures.snapshot([[PasteboardTypes.png: BenchFixtures.png]])
        ), case .capture(let imageWithTIFF) = PasteboardClassifier().classify(
            Fixtures.snapshot([[PasteboardTypes.png: BenchFixtures.pngVariant(1), PasteboardTypes.tiff: BenchFixtures.tiff]])
        ) else { return XCTFail("image did not classify") }
        _ = try await store.insert(image)
        _ = try await store.insert(imageWithTIFF)
        let urls = try BenchFixtures.files(count: 500, in: directory)
        guard case .capture(let files) = PasteboardClassifier().classify(
            Fixtures.snapshot(urls.map { [PasteboardTypes.fileURL: $0.dataRepresentation] })
        ) else { return XCTFail("files did not classify") }
        _ = try await store.insert(files)

        let rows = try await store.page()
        let cases: [(String, ClipItem, Int)] = [
            ("text 20 B", try XCTUnwrap(rows.first { $0.title == "a short line of text" }), 50),
            ("text 5 MB", try XCTUnwrap(rows.first { $0.kind == .text && $0.byteSize > 1_000_000 }), 8),
            ("image PNG \(BenchFixtures.png.count / 1_000_000) MB", try XCTUnwrap(rows.first { $0.hash == image.hash }), 8),
            ("image PNG + rebuilt TIFF", try XCTUnwrap(rows.first { $0.hash == imageWithTIFF.hash }), 5),
            ("500 files", try XCTUnwrap(rows.first { $0.kind == .file }), 8),
        ]
        for (name, item, iterations) in cases {
            var total: [Duration] = []
            var read: [Duration] = []
            var write: [Duration] = []
            var prepare: [Duration] = []
            for _ in 0..<iterations {
                let start = ContinuousClock.now
                let copied = await copier.copy(item)
                total.append(ContinuousClock.now - start)
                XCTAssertTrue(copied)

                let readStart = ContinuousClock.now
                let payload = try await store.payload(for: item.id)
                read.append(ContinuousClock.now - readStart)
                let prepareStart = ContinuousClock.now
                let prepared = PasteboardWriter.prepare(try XCTUnwrap(payload))
                prepare.append(ContinuousClock.now - prepareStart)
                let writeStart = ContinuousClock.now
                PasteboardWriter.write(prepared, to: pasteboard)
                write.append(ContinuousClock.now - writeStart)
            }
            Bench.print("copy \(name): end to end", total)
            Bench.print("copy \(name): store payload read", read)
            Bench.print("copy \(name): prepare, off the main thread for files", prepare)
            Bench.print("copy \(name): write on the main thread", write)
        }
    }

    func testResolvingFilesOneByOne() async throws {
        let urls = try BenchFixtures.files(count: 500, in: directory)
        let files = urls.map { FileReference(path: $0.path, bookmark: PasteboardClassifier.bookmark(for: $0)) }
        Bench.report("resolve 500 bookmarks and check each file, one by one", iterations: 8) {
            let resolved = files.map(PasteboardWriter.resolve)
            _ = resolved.contains { !FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    // MARK: - Menu

    func testMenuBuild() async throws {
        let store = try ClipStore(location: StoreLocation(root: directory))
        let generator = ThumbnailGenerator(store: store)
        for index in 0..<4 {
            _ = try await store.insert(Fixtures.textCapture("menu row \(index) " + String(repeating: "word ", count: 80)))
        }
        for index in 0..<3 {
            guard case .capture(let capture) = PasteboardClassifier().classify(
                Fixtures.snapshot([[PasteboardTypes.png: BenchFixtures.pngVariant(index)]])
            ) else { return XCTFail("image did not classify") }
            _ = try await store.insert(capture)
            _ = await generator.generate(for: capture)
        }
        let urls = try BenchFixtures.files(count: 3, in: directory)
        for url in urls {
            _ = try await store.insert(Fixtures.fileCapture([url.path]))
        }

        let controller = MenuBarController(
            store: store,
            actions: .init(openPanel: {}, copy: { _ in }, clearHistory: {}, openSettings: {}),
            updater: nil,
            statusBar: nil
        )
        await BenchFixtures.spin {
            controller.menuNeedsUpdate(controller.menu)
            return controller.menu.items.count >= 10 + 6
        }
        ThumbnailCache.shared.removeAll()

        var cold: [Duration] = []
        let coldStart = ContinuousClock.now
        controller.menuNeedsUpdate(controller.menu)
        cold.append(ContinuousClock.now - coldStart)
        Bench.print("menu build, thumbnails not cached", cold)

        try await Task.sleep(for: .milliseconds(500))
        var warm: [Duration] = []
        for _ in 0..<200 {
            let start = ContinuousClock.now
            controller.menuNeedsUpdate(controller.menu)
            warm.append(ContinuousClock.now - start)
        }
        Bench.print("menu build, thumbnails cached", warm)
        controller.menuDidClose(controller.menu)

        var refresh: [Duration] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            for _ in 0..<20 { NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil) }
            for _ in 0..<4 { await Task.yield() }
            _ = try await store.count()
            for _ in 0..<4 { await Task.yield() }
            _ = try await store.count()
            refresh.append(ContinuousClock.now - start)
        }
        Bench.print("20 history changes at once: menu refresh until settled", refresh)
    }
}

// MARK: - Helpers

enum Bench {
    static func report(_ name: String, iterations: Int, _ body: () -> Void) {
        body()
        var samples: [Duration] = []
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            body()
            samples.append(ContinuousClock.now - start)
        }
        print(name, samples)
    }

    static func print(_ name: String, _ samples: [Duration]) {
        let sorted = samples.sorted()
        guard let fastest = sorted.first else { return }
        let median = sorted[sorted.count / 2]
        Swift.print("BENCH \(name): min \(format(fastest)), median \(format(median)), n=\(sorted.count)")
    }

    private static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        if seconds >= 1 { return String(format: "%.2f s", seconds) }
        if seconds >= 0.001 { return String(format: "%.2f ms", seconds * 1_000) }
        return String(format: "%.2f us", seconds * 1_000_000)
    }
}

enum BenchFixtures {
    static let width = 3_840
    static let height = 2_160

    static func text(megabytes: Int) -> String {
        let line = "The quick brown fox jumps over the lazy dog, then copies it to the clipboard.\n"
        return String(repeating: line, count: megabytes * 1_048_576 / line.utf8.count)
    }

    /// The picture has gradients and shapes, so its PNG has a realistic size.
    static func image(seed: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        var generator = SystemRandomNumberGenerator()
        let colors = [CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1), CGColor(red: 0.9, green: 0.6, blue: 0.2, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil)!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        for index in 0..<(400 + seed) {
            let rect = CGRect(
                x: Int.random(in: 0..<width, using: &generator), y: Int.random(in: 0..<height, using: &generator),
                width: Int.random(in: 4..<300, using: &generator), height: Int.random(in: 4..<200, using: &generator)
            )
            context.setFillColor(CGColor(
                red: CGFloat(index % 7) / 7, green: CGFloat(index % 11) / 11, blue: CGFloat(index % 13) / 13, alpha: 0.6
            ))
            context.fillEllipse(in: rect)
        }
        return context.makeImage()!
    }

    static let png: Data = ImageProcessing.pngData(from: image(seed: 0))!
    static let tiff: Data = {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image(seed: 0), nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }()

    private static var variants: [Int: Data] = [:]

    static func pngVariant(_ index: Int) -> Data {
        if let cached = variants[index] { return cached }
        let data = ImageProcessing.pngData(from: image(seed: index + 1))!
        variants[index] = data
        return data
    }

    static func files(count: Int, in directory: URL) throws -> [URL] {
        let folder = directory.appendingPathComponent("files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            let url = folder.appendingPathComponent("document-\(index).txt")
            try Data("file \(index)".utf8).write(to: url)
            return url
        }
    }

    static func fill(_ store: ClipStore, rows: Int) async throws {
        for index in 0..<rows {
            _ = try await store.insert(
                Fixtures.textCapture("row \(index)"),
                at: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index))
            )
        }
    }

    /// When this call returns, every read queued before it has finished and its result has been
    /// applied.
    @MainActor
    static func settle(_ store: ClipStore) async throws {
        for _ in 0..<3 {
            for _ in 0..<5 { await Task.yield() }
            _ = try await store.count()
        }
        for _ in 0..<5 { await Task.yield() }
    }

    /// It waits on the main actor without a timer, so the wait adds microseconds instead of a poll
    /// interval.
    @MainActor
    static func spin(timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "condition not met in time")
    }

    @MainActor
    static func draw(_ image: NSImage, side: Int) {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
    }
}

import XCTest
@testable import ClipDeck

/// The store benchmarks use a seeded history. They are skipped unless `CLIPDECK_BENCH` is set.
/// xcodebuild forwards it from `TEST_RUNNER_CLIPDECK_BENCH`. `CLIPDECK_BENCH_ROWS` sets the history
/// size and `CLIPDECK_BENCH_OUT` names a file that receives the result lines.
final class ClipStoreBenchmarks: XCTestCase {
    private var directory: URL!
    private var store: ClipStore!
    private var lines: [String] = []

    private static let environment = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.environment["CLIPDECK_BENCH"] != nil, "set TEST_RUNNER_CLIPDECK_BENCH=1 to run the benchmarks")
        directory = Fixtures.temporaryDirectory()
        store = try ClipStore(location: StoreLocation(root: directory))
    }

    override func tearDownWithError() throws {
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Reporting

    private func report(_ name: String, _ value: Double, _ unit: String) {
        let line = "BENCH\t\(name)\t\(String(format: "%.1f", value))\t\(unit)"
        lines.append(line)
        print(line)
    }

    private func flush() {
        guard let path = Self.environment["CLIPDECK_BENCH_OUT"] else { return }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Wall time and process CPU time are both measured in millionths of a second. CPU time
    /// excludes time spent waiting for a processor or the disk, so it changes less with the
    /// machine's load.
    private struct Cost {
        var wall = 0.0
        var cpu = 0.0

        static func += (total: inout Cost, cost: Cost) {
            total.wall += cost.wall
            total.cpu += cost.cpu
        }
    }

    private func measure(_ body: () async throws -> Void) async rethrows -> Cost {
        let cpu = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        let wall = DispatchTime.now().uptimeNanoseconds
        try await body()
        return Cost(
            wall: Double(DispatchTime.now().uptimeNanoseconds - wall) / 1_000,
            cpu: Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpu) / 1_000
        )
    }

    private func throughput(_ name: String, rows: Int, _ cost: Cost) {
        report(name, Double(rows) / (cost.wall / 1_000_000), "rows/s")
        report("\(name)_cpu", Double(rows) / (cost.cpu / 1_000_000), "rows/cpu-s")
    }

    /// Reports the median and 95th percentile wall time for one call, and the median CPU time per
    /// call.
    private func latency(_ name: String, iterations: Int, _ body: () async throws -> Void) async rethrows {
        for _ in 0..<3 { try await body() }
        var samples: [Cost] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            samples.append(try await measure(body))
        }
        let wall = samples.map(\.wall).sorted()
        let cpu = samples.map(\.cpu).sorted()
        report("\(name)_p50", wall[wall.count / 2], "us")
        report("\(name)_p95", wall[min(wall.count - 1, wall.count * 95 / 100)], "us")
        report("\(name)_cpu_p50", cpu[cpu.count / 2], "cpu-us")
    }

    // MARK: - The benchmark

    func testStoreBenchmark() async throws {
        let rows = Int(Self.environment["CLIPDECK_BENCH_ROWS"] ?? "") ?? 100_000
        var generator = HistoryGenerator()
        report("rows", Double(rows), "rows")

        // Seeding also measures throughput for new rows.
        var cost = Cost()
        let chunk = 5_000
        for start in stride(from: 0, to: rows, by: chunk) {
            let captures = (start..<min(start + chunk, rows)).map { generator.capture($0) }
            for (offset, capture) in captures.enumerated() {
                let date = HistoryGenerator.date(start + offset)
                cost += try await measure { _ = try await store.insert(capture, at: date) }
            }
        }
        throughput("insert_new_seed", rows: rows, cost)

        var next = rows
        func insertAll(_ captures: [Capture]) async throws -> Cost {
            var cost = Cost()
            for (offset, capture) in captures.enumerated() {
                let date = HistoryGenerator.date(next + offset)
                cost += try await measure { _ = try await store.insert(capture, at: date) }
            }
            next += captures.count
            return cost
        }
        throughput("insert_new_at_size", rows: 5_000, try await insertAll((0..<5_000).map { generator.capture(next + $0) }))

        _ = try await store.setStorageBudget(.max / 4)
        throughput("insert_new_with_limit", rows: 5_000, try await insertAll((0..<5_000).map { generator.capture(next + $0) }))
        _ = try await store.setStorageBudget(nil)

        // Copy rows spread across the history again, then copy the newest row again.
        var replay = HistoryGenerator()
        let repeats = stride(from: 0, to: rows, by: max(1, rows / 5_000)).map { replay.capture($0) }
        throughput("insert_bump", rows: repeats.count, try await insertAll(repeats))
        if let newest = repeats.last {
            throughput("insert_bump_newest", rows: 2_000, try await insertAll(Array(repeating: newest, count: 2_000)))
        }

        let total = try await store.count()
        report("rows_after_seed", Double(total), "rows")
        let files = [store.location.database.path, store.location.database.path + "-wal"]
        let bytes = files.reduce(Int64(0)) { $0 + PasteboardClassifier.size(ofFileAt: $1) }
        report("database_size", Double(bytes) / 1_000_000, "MB")

        try await measureReads(total: total)
        try await measurePayloads(generator: &generator, next: &next)
        try await measureBlockedReads(next: &next)
        try await measureRemoval()
        flush()
    }

    /// This times the step from schema version 4 to 5 over a seeded history in the format that a
    /// version 4 build wrote. The app runs the step when it opens the store, before it opens its
    /// first window.
    func testMigrationFromVersionFourBenchmark() async throws {
        let rows = Int(Self.environment["CLIPDECK_BENCH_ROWS"] ?? "") ?? 100_000
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = StoreLocation(root: root)
        var generator = HistoryGenerator()
        do {
            let db = try VersionFourFixture.open(at: location)
            for start in stride(from: 0, to: rows, by: 5_000) {
                try db.transaction {
                    for index in start..<min(start + 5_000, rows) {
                        let capture = generator.capture(index)
                        let seconds = HistoryGenerator.date(index).timeIntervalSince1970
                        try VersionFourFixture.insert(VersionFourFixture.Row(
                            id: Int64(index + 1), hash: capture.hash, kind: capture.kind, createdAt: seconds, lastUsed: seconds,
                            title: capture.title, detail: capture.detail, text: Data(capture.searchText.utf8), byteSize: capture.byteSize,
                            blobType: capture.blob?.type, offersTIFF: capture.offersTIFF, offersPlainText: capture.offersPlainText,
                            thumbSize: capture.kind == .text ? 0 : 40_000, representations: capture.representations, files: capture.files
                        ), into: db)
                    }
                }
            }
        }
        report("migration_rows", Double(rows), "rows")
        report("migration_database_before", Double(PasteboardClassifier.size(ofFileAt: location.database.path)) / 1_000_000, "MB")

        var migrated: ClipStore?
        let migration = try await measure { migrated = try ClipStore(location: location) }
        report("migration_v4_to_v5", migration.wall / 1_000, "ms")
        report("migration_v4_to_v5_cpu", migration.cpu / 1_000, "cpu-ms")
        let version = try await XCTUnwrap(migrated).schemaVersionOnDisk()
        XCTAssertEqual(version, ClipStore.schemaVersion)
        let files = [location.database.path, location.database.path + "-wal"]
        let bytes = files.reduce(Int64(0)) { $0 + PasteboardClassifier.size(ofFileAt: $1) }
        report("migration_database_and_log_after", Double(bytes) / 1_000_000, "MB")
        try StoreInspector.assertSound(at: location)

        migrated = nil
        let reopen = try await measure { migrated = try ClipStore(location: location) }
        report("open_at_version_5", reopen.wall / 1_000, "ms")
        report("migration_database_after_close", Double(PasteboardClassifier.size(ofFileAt: location.database.path)) / 1_000_000, "MB")
        flush()
    }

    private func cursor(atDepth depth: Int) async throws -> PageCursor {
        // A second connection reads the row at that depth without touching the store's statements.
        let db = try Database(path: store.location.database.path)
        let row = try db.query(
            "SELECT id, last_used FROM items ORDER BY last_used DESC, id DESC LIMIT 1 OFFSET ?", [.int(Int64(depth))]
        ) { ($0.int64(0), $0.double(1)) }.first
        let (id, lastUsed) = try XCTUnwrap(row)
        return PageCursor(after: ClipItem(
            id: id, hash: "", kind: .text, createdAt: Date(), lastUsed: Date(timeIntervalSince1970: lastUsed),
            title: "", detail: nil, preview: "", byteSize: 0, blobType: nil, fileCount: 0, isMissing: false
        ))
    }

    private func measureReads(total: Int) async throws {
        let middle = try await cursor(atDepth: total / 2)
        let deep = try await cursor(atDepth: total * 9 / 10)

        try await latency("page_first", iterations: 200) { _ = try await store.page() }
        try await latency("page_menu_10", iterations: 200) { _ = try await store.page(limit: 10) }
        try await latency("page_middle", iterations: 200) { _ = try await store.page(after: middle) }
        try await latency("page_deep", iterations: 200) { _ = try await store.page(after: deep) }

        let rare = try await store.search(HistoryGenerator.rareWord)
        report("search_rare_matches", Double(rare.count), "rows")
        try await latency("search_rare", iterations: 100) { _ = try await store.search(HistoryGenerator.rareWord) }
        try await latency("search_prefix2_common", iterations: 30) { _ = try await store.search("th") }
        try await latency("search_prefix2_common_middle", iterations: 30) { _ = try await store.search("th", after: middle) }
        try await latency("search_prefix3", iterations: 30) { _ = try await store.search("con") }
        try await latency("search_word_common", iterations: 30) { _ = try await store.search("error") }
        try await latency("search_prefix4_common", iterations: 30) { _ = try await store.search("http") }
        try await latency("search_multiword", iterations: 30) { _ = try await store.search("error conn") }
        try await latency("search_multiword_rare", iterations: 100) {
            _ = try await store.search("\(HistoryGenerator.rareWord) th")
        }
        try await latency("search_unique_token", iterations: 100) { _ = try await store.search("ref00012345") }

        let db = try Database(path: store.location.database.path)
        let matches = try db.scalarInt("SELECT count(*) FROM items_fts WHERE items_fts MATCH ?", [.text("\"th\"*")]) ?? 0
        report("search_prefix2_common_matches", Double(matches), "rows")

        try await latency("count", iterations: 30) { _ = try await store.count() }
        try await latency("storage_usage", iterations: 1_000) { _ = try await store.storageUsage() }
        let everything = ClearRequest(range: .allTime, kinds: Set(ClipKind.allCases))
        try await latency("count_matching_all", iterations: 30) { _ = try await store.count(matching: everything) }
        // The newest rows carry the newest dates, so this window holds the last hour of copies.
        let recent = ClearRequest(range: .lastHour, kinds: [.text], now: HistoryGenerator.date(total))
        try await latency("count_matching_text_last_hour", iterations: 100) { _ = try await store.count(matching: recent) }
        try await latency("text_preview", iterations: 200) { _ = try await store.textPreview(for: Int64(total / 2)) }
    }

    private func measurePayloads(generator: inout HistoryGenerator, next: inout Int) async throws {
        let db = try Database(path: store.location.database.path)
        func firstID(_ sql: String) throws -> Int64 { try XCTUnwrap(try db.scalarInt(sql)) }
        let plain = try firstID(
            "SELECT id FROM items WHERE kind = 0 AND NOT EXISTS (SELECT 1 FROM representations WHERE item_id = items.id) ORDER BY id LIMIT 1 OFFSET 500"
        )
        let rich = try firstID("SELECT item_id FROM representations GROUP BY item_id HAVING count(*) > 1 ORDER BY item_id LIMIT 1 OFFSET 50")
        let file = try firstID("SELECT id FROM items WHERE kind = 2 ORDER BY id LIMIT 1 OFFSET 50")
        let smallImage = try firstID("SELECT id FROM items WHERE kind = 1 ORDER BY id LIMIT 1 OFFSET 50")

        try await latency("payload_text", iterations: 300) { _ = try await store.payload(for: plain) }
        try await latency("payload_rich_text", iterations: 300) { _ = try await store.payload(for: rich) }
        try await latency("payload_file", iterations: 300) { _ = try await store.payload(for: file) }
        try await latency("payload_image_small", iterations: 300) { _ = try await store.payload(for: smallImage) }

        let large = generator.blobCapture(next, bytes: 12 * 1024 * 1024)
        var outcome: InsertOutcome?
        let insertTime = try await measure { outcome = try await store.insert(large, at: HistoryGenerator.date(next)) }
        next += 1
        report("insert_image_12mb", insertTime.wall, "us")
        let largeID = try XCTUnwrap(outcome).id
        try await latency("payload_image_12mb", iterations: 40) {
            let payload = try await store.payload(for: largeID)
            XCTAssertEqual(payload?.blob?.data.count, 12 * 1024 * 1024)
        }

        guard case .capture(let screenshot) = Fixtures.classifier().classify(Fixtures.snapshot([[
            PasteboardTypes.tiff: Fixtures.tiff(width: 2_000, height: 1_200),
        ]])) else { return XCTFail("the screenshot did not classify") }
        let screenshotID = try await store.insert(screenshot, at: HistoryGenerator.date(next)).id
        next += 1
        try await latency("payload_image_rebuilds_tiff", iterations: 20) { _ = try await store.payload(for: screenshotID) }

        let png = Fixtures.png(width: 512, height: 512)
        try await latency("save_thumbnail", iterations: 100) { _ = try await store.saveThumbnail(png, for: large.hash) }
    }

    /// Measures how long a list read waits while large images are being stored.
    private func measureBlockedReads(next: inout Int) async throws {
        let generator = HistoryGenerator()
        let images = (0..<12).map { generator.blobCapture(next + $0, bytes: 12 * 1024 * 1024) }
        let base = next
        next += images.count
        let store: ClipStore = self.store
        let finished = Flag()
        let writer = Task {
            defer { finished.set() }
            for (offset, image) in images.enumerated() {
                _ = try await store.insert(image, at: HistoryGenerator.date(base + offset))
            }
        }
        var samples: [Double] = []
        while !finished.isSet {
            samples.append(try await measure { _ = try await store.page() }.wall)
        }
        try await writer.value
        samples.sort()
        report("page_first_during_image_inserts_samples", Double(samples.count), "calls")
        report("page_first_during_image_inserts_p50", samples[samples.count / 2], "us")
        report("page_first_during_image_inserts_p95", samples[min(samples.count - 1, samples.count * 95 / 100)], "us")
        report("page_first_during_image_inserts_max", samples[samples.count - 1], "us")
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    private func measureRemoval() async throws {
        let db = try Database(path: store.location.database.path)
        let evictions = 5_000
        let freed = try XCTUnwrap(try db.scalarInt(
            "SELECT sum(b) FROM (SELECT \(ClipStore.storedBytesSQL) AS b FROM items ORDER BY last_used ASC, id ASC LIMIT \(evictions))"
        ))
        let used = try await store.storageUsage()
        var removed = 0
        let evictTime = try await measure { removed = try await store.setStorageBudget(used - freed) }
        report("evict_rows", Double(removed), "rows")
        throughput("evict", rows: removed, evictTime)
        _ = try await store.setStorageBudget(nil)

        let newest = try XCTUnwrap(try db.query("SELECT max(last_used) FROM items") { $0.double(0) }.first)
        let hour = ClearRequest(range: .lastHour, kinds: Set(ClipKind.allCases), now: Date(timeIntervalSince1970: newest))
        var cleared = 0
        let hourTime = try await measure { cleared = try await store.clear(hour) }
        report("clear_last_hour_rows", Double(cleared), "rows")
        throughput("clear_last_hour", rows: cleared, hourTime)

        let everything = ClearRequest(range: .allTime, kinds: Set(ClipKind.allCases))
        let allTime = try await measure { cleared = try await store.clear(everything) }
        report("clear_all_rows", Double(cleared), "rows")
        throughput("clear_all", rows: cleared, allTime)
        report("clear_all_total", allTime.wall / 1_000, "ms")
    }
}

/// The deterministic history contains mostly text of varied lengths drawn from a skewed vocabulary,
/// plus some rich text, images, and files.
struct HistoryGenerator {
    static let rareWord = "zyzzyva"

    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    private let vocabulary: [String]
    private let noise: Data

    init() {
        let common = [
            "the", "this", "that", "then", "there", "they", "https", "http", "error", "connection", "config", "const",
            "context", "content", "import", "func", "return", "value", "string", "data", "file", "path", "user", "name",
            "thanks", "think", "through", "thread", "throw", "theme", "com", "www", "amazon", "github", "status", "request",
            "response", "service", "server", "client", "update", "build", "test", "release", "version", "branch", "commit",
            "review", "meeting", "tomorrow", "today", "please", "hello", "team", "account", "password", "address", "phone",
            "email", "order", "invoice", "total", "price", "table", "index", "query", "select", "insert", "delete", "where",
            "from", "with", "have", "will", "would", "could", "should", "about", "which", "their", "other", "after",
            "first", "second", "number", "report", "project", "design", "document", "comment", "question", "answer",
        ]
        let syllables = ["ka", "lo", "mi", "ne", "su", "ta", "ri", "po", "ve", "da", "zu", "be", "co", "fi", "gu", "ha"]
        var words = common
        var seed: UInt64 = 42
        while words.count < 4_000 {
            var word = ""
            for _ in 0..<(2 + Int(Self.next(&seed) % 3)) {
                word += syllables[Int(Self.next(&seed) % UInt64(syllables.count))]
            }
            words.append(word)
        }
        vocabulary = words
        var bytes = [UInt8](repeating: 0, count: 1 << 20)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: Self.next(&seed)) }
        noise = Data(bytes)
    }

    static func date(_ index: Int) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
    }

    private static func next(_ state: inout UInt64) -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private mutating func random() -> UInt64 { Self.next(&state) }

    private mutating func unit() -> Double { Double(random() >> 11) / Double(1 << 53) }

    private mutating func word() -> String {
        let skewed = unit() * unit() * unit()
        return vocabulary[Int(skewed * Double(vocabulary.count))]
    }

    private mutating func text(_ index: Int) -> String {
        let roll = unit()
        let count: Int
        switch roll {
        case ..<0.55: count = 1 + Int(random() % 12)
        case ..<0.90: count = 20 + Int(random() % 180)
        case ..<0.99: count = 400 + Int(random() % 1_600)
        default: count = 6_000 + Int(random() % 6_000)
        }
        var words: [String] = []
        words.reserveCapacity(count + 2)
        for position in 0..<count {
            words.append(word())
            if position % 17 == 16 { words.append("\n") }
        }
        words.append(String(format: "ref%08d", index))
        if index % 20_000 == 7 { words.append(Self.rareWord) }
        return words.joined(separator: " ")
    }

    private func hash(_ index: Int) -> String {
        var seed = UInt64(index) &* 0x2545_F491_4F6C_DD1D &+ 1
        return (0..<4).map { _ in String(format: "%016llx", Self.next(&seed)) }.joined()
    }

    private func bytes(_ count: Int, marker: Int) -> Data {
        var data = Data(capacity: count)
        withUnsafeBytes(of: UInt64(marker)) { data.append(contentsOf: $0) }
        while data.count < count {
            data.append(noise.prefix(min(noise.count, count - data.count)))
        }
        return data
    }

    func blobCapture(_ index: Int, bytes count: Int) -> Capture {
        Capture(
            kind: .image, hash: hash(index), title: "Image \(index)", detail: nil, searchText: "Image \(index)",
            byteSize: Int64(count), representations: [], offersPlainText: false, files: [],
            blob: PasteboardRepresentation(type: PasteboardTypes.png, data: bytes(count, marker: index)), offersTIFF: false
        )
    }

    mutating func capture(_ index: Int) -> Capture {
        let roll = unit()
        if roll < 0.02 {
            let size = 8_192 + Int(random() % 57_344)
            let companions = unit() < 0.3
                ? [PasteboardRepresentation(type: PasteboardTypes.html, data: Data("<img src=\"https://example.com/\(index).png\">".utf8))]
                : []
            return Capture(
                kind: .image, hash: hash(index), title: "Image \(index)", detail: nil, searchText: "Image \(index)",
                byteSize: Int64(size), representations: companions, offersPlainText: false, files: [],
                blob: PasteboardRepresentation(type: PasteboardTypes.png, data: bytes(size, marker: index)), offersTIFF: false
            )
        }
        if roll < 0.07 {
            let present = unit() < 0.5
            let first = present ? "/usr/bin/env" : "/Users/someone/Documents/Project \(index % 97)/\(word())-\(index).pdf"
            var paths = [first]
            for extra in 0..<Int(random() % 3) {
                paths.append("/Users/someone/Downloads/\(word())-\(index)-\(extra).png")
            }
            if present { paths.append("/Users/someone/Desktop/\(word())-\(index).txt") }
            let name = (first as NSString).lastPathComponent
            return Capture(
                kind: .file, hash: hash(index), title: paths.count == 1 ? name : "\(name) and \(paths.count - 1) more",
                detail: first, searchText: paths.joined(separator: "\n"), byteSize: Int64(1_000 + index),
                representations: [], offersPlainText: false,
                files: paths.map { FileReference(path: $0, bookmark: Data("bookmark:\($0)".utf8)) }, blob: nil, offersTIFF: false
            )
        }
        let body = text(index)
        var representations: [PasteboardRepresentation] = []
        var size = body.utf8.count
        if roll < 0.15 {
            let rtf = Data("{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0\\fs24 \(body)}".utf8)
            let html = Data("<meta charset=\"utf-8\"><span style=\"font-family: Helvetica; font-size: 12px\">\(body)</span>".utf8)
            representations = [
                PasteboardRepresentation(type: PasteboardTypes.rtf, data: rtf),
                PasteboardRepresentation(type: PasteboardTypes.html, data: html),
            ]
            size += rtf.count + html.count
        }
        return Capture(
            kind: .text, hash: hash(index), title: PasteboardClassifier.firstLine(of: body), detail: nil, searchText: body,
            byteSize: Int64(size), representations: representations, offersPlainText: true, files: [], blob: nil, offersTIFF: false
        )
    }
}

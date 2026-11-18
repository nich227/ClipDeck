import XCTest
@testable import ClipDeck

/// Runs a seeded random sequence against a store and a plain model of the store. The sequence has
/// copies, repeat copies, panel copies, thumbnail saves, limits, and clears. At intervals and at
/// the end, the test compares the store with the model across the list, searches, byte counter, and
/// files on disk. It also runs the database's own checks.
///
/// One seed runs with the suite. `CLIPDECK_MODEL_SEEDS` (comma separated) names more seeds to run,
/// and `CLIPDECK_MODEL_STEPS` sets the number of steps for them. xcodebuild forwards both from
/// `TEST_RUNNER_` variables.
final class ClipStoreModelTests: XCTestCase {
    private static let environment = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = false
    }

    func testARandomHistoryMatchesTheModel() async throws {
        try await run(seed: 0x5EED, steps: 3_000)
    }

    func testRandomHistoriesMatchTheModelForTheGivenSeeds() async throws {
        let seeds = (Self.environment["CLIPDECK_MODEL_SEEDS"] ?? "").split(separator: ",").compactMap { UInt64($0) }
        try XCTSkipIf(seeds.isEmpty, "set TEST_RUNNER_CLIPDECK_MODEL_SEEDS=1,2,3 to run more seeds")
        let steps = Int(Self.environment["CLIPDECK_MODEL_STEPS"] ?? "") ?? 3_000
        for seed in seeds {
            try await run(seed: seed, steps: steps)
        }
    }

    // MARK: - The model

    private struct Row {
        let id: Int64
        let capture: Capture
        var byteSize: Int64
        var lastUsed: Double
        var thumbnail: Data?
        var representations: [PasteboardRepresentation]
        var files: [FileReference]
        var offersPlainText: Bool

        var storedBytes: Int64 { (capture.kind == .file ? 0 : byteSize) + Int64(thumbnail?.count ?? 0) }
    }

    private struct Model {
        /// The newest copy comes first.
        var rows: [Row] = []
        var budget: Int64?

        var storedBytes: Int64 { rows.reduce(0) { $0 + $1.storedBytes } }

        /// Each copy is stored after all previous copies, whatever the clock says.
        func time(for date: Double) -> Double {
            guard let newest = rows.first else { return date }
            return max(date, newest.lastUsed.nextUp)
        }

        mutating func moveToTop(_ index: Int, at date: Double) {
            let time = time(for: date)
            var row = rows.remove(at: index)
            row.lastUsed = time
            rows.insert(row, at: 0)
        }

        /// Removes the oldest rows one batch at a time, as the store does, and returns the number
        /// of rows removed.
        mutating func evict() -> Int {
            guard let budget else { return 0 }
            var removed = 0
            while true {
                let total = storedBytes
                guard total > budget, let newest = rows.first else { return removed }
                let candidates = rows.reversed().prefix(Constants.Storage.evictionBatch).map {
                    EvictionCandidate(id: $0.id, hash: $0.capture.hash, bytes: $0.storedBytes)
                }
                let plan = Set(EvictionPlan.select(from: candidates, excess: total - budget, keeping: newest.id).map(\.id))
                rows.removeAll { plan.contains($0.id) }
                removed += plan.count
                if plan.count < Constants.Storage.evictionBatch { return removed }
            }
        }
    }

    private static let vocabulary = [
        "alpha", "alpine", "al", "beta", "bet", "better", "gamma", "delta", "del", "configuration", "connect", "con", "co", "c",
        "x", "caf\u{E9}", "na\u{EF}ve", "z\u{FC}rich", "42", "4242", "a1b2", "\u{65E5}\u{672C}\u{8A9E}", "\u{65E5}\u{672C}", "zebra",
        "Zeta", "OMEGA",
    ]

    // MARK: - The run

    private func run(seed: UInt64, steps: Int) async throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipStore(location: StoreLocation(root: directory))
        let db = try Database(path: store.location.database.path)
        var random = SeededGenerator(seed: seed)
        var model = Model()
        var clock = 1_800_000_000.0
        var unique = 0
        // This represents text or a whole capture that was copied before and can be copied again.
        var texts: [String] = []
        var others: [Capture] = []
        let images = (0..<10).map { Fixtures.imageCapture(width: 4 + $0, height: 3) }
        let thumbnails = (0..<4).map { Fixtures.png(width: 2 + $0, height: 2) }

        for step in 0..<steps {
            let drift = Double.random(in: 0..<1, using: &random)
            if drift < 0.7 {
                clock += Double(Int.random(in: 1...120, using: &random))
            } else if drift > 0.85 {
                clock -= Double(Int.random(in: 1...600, using: &random))
            }
            let date = Date(timeIntervalSince1970: clock)
            let context = "seed \(seed) step \(step)"
            let roll = Double.random(in: 0..<1, using: &random)

            if roll < 0.55 {
                let capture: Capture
                let kind = Double.random(in: 0..<1, using: &random)
                if kind < 0.7 {
                    let text: String
                    if !texts.isEmpty, random.chance(0.35) {
                        text = random.pick(texts)
                    } else {
                        unique += 1
                        var words = (0..<Int.random(in: 1...5, using: &random)).map { _ in random.pick(Self.vocabulary) }
                        words.append("u\(unique)")
                        if random.chance(0.1) { words += Array(repeating: random.pick(Self.vocabulary), count: 120) }
                        if random.chance(0.05) { words.insert("nul\u{0}tail", at: Int.random(in: 0...words.count, using: &random)) }
                        text = words.joined(separator: " ")
                        texts.append(text)
                    }
                    capture = Fixtures.textCapture(text, rtf: random.chance(0.3) ? Data("{\\rtf1 \(Int.random(in: 0...3, using: &random))}".utf8) : nil)
                } else if kind < 0.85 {
                    capture = random.pick(images)
                } else if !others.isEmpty, random.chance(0.35) {
                    capture = random.pick(others)
                } else {
                    unique += 1
                    let paths = (0..<Int.random(in: 1...3, using: &random)).map { "/tmp/model/\(random.pick(Self.vocabulary)) \(unique)-\($0).txt" }
                    capture = Fixtures.fileCapture(paths)
                    others.append(capture)
                }
                let outcome = try await store.insert(capture, at: date)
                if let index = model.rows.firstIndex(where: { $0.capture.hash == capture.hash }) {
                    XCTAssertEqual(outcome, .bumped(model.rows[index].id), context)
                    model.rows[index].byteSize = capture.byteSize
                    model.rows[index].representations = capture.representations
                    model.rows[index].files = capture.files
                    model.rows[index].offersPlainText = capture.offersPlainText
                    model.moveToTop(index, at: clock)
                } else {
                    guard case .inserted(let id) = outcome else { return XCTFail("\(context): expected a new row, got \(outcome)") }
                    XCTAssertFalse(model.rows.contains { $0.id == id }, context)
                    model.rows.insert(Row(
                        id: id, capture: capture, byteSize: capture.byteSize, lastUsed: model.time(for: clock), thumbnail: nil,
                        representations: capture.representations, files: capture.files, offersPlainText: capture.offersPlainText
                    ), at: 0)
                }
                _ = model.evict()
            } else if roll < 0.75 {
                if !model.rows.isEmpty, random.chance(0.9) {
                    let index = Int.random(in: 0..<model.rows.count, using: &random)
                    try await store.touch(id: model.rows[index].id, at: date)
                    model.moveToTop(index, at: clock)
                } else {
                    try await store.touch(id: 1_000_000 + Int64(step), at: date)
                }
            } else if roll < 0.87 {
                let png = random.pick(thumbnails)
                let owners = model.rows.indices.filter { model.rows[$0].capture.kind != .text }
                if !owners.isEmpty, random.chance(0.85) {
                    let index = random.pick(owners)
                    let saved = try await store.saveThumbnail(png, for: model.rows[index].capture.hash)
                    XCTAssertTrue(saved, context)
                    model.rows[index].thumbnail = png
                    _ = model.evict()
                } else {
                    let saved = try await store.saveThumbnail(png, for: "no-such-hash-\(step)")
                    XCTAssertFalse(saved, context)
                }
            } else if roll < 0.95 {
                model.budget = random.chance(0.3) ? nil : Int64.random(in: 200...60_000, using: &random)
                let removed = try await store.setStorageBudget(model.budget)
                XCTAssertEqual(removed, model.evict(), context)
            } else {
                let mask = Int.random(in: 0..<8, using: &random)
                let kinds = Set(ClipKind.allCases.filter { mask & (1 << $0.rawValue) != 0 })
                let request = ClearRequest(range: random.pick(ClearRange.allCases), kinds: kinds, now: date)
                let doomed = Set(model.rows.filter { row in
                    kinds.contains(row.capture.kind) && (request.cutoff.map { row.lastUsed >= $0.timeIntervalSince1970 } ?? true)
                }.map(\.id))
                let counted = try await store.count(matching: request)
                XCTAssertEqual(counted, doomed.count, context)
                let removed = try await store.clear(request)
                XCTAssertEqual(removed, doomed.count, context)
                model.rows.removeAll { doomed.contains($0.id) }
            }

            if step % 149 == 148 || step == steps - 1 {
                try await verify(store, db, model, &random, context)
            }
        }
    }

    // MARK: - The comparison

    private func verify(_ store: ClipStore, _ db: Database, _ model: Model, _ random: inout SeededGenerator, _ context: String) async throws {
        var listed: [ClipItem] = []
        var cursor: PageCursor?
        while true {
            let page = try await store.page(after: cursor, limit: 41)
            guard let last = page.last else { break }
            listed += page
            cursor = PageCursor(after: last)
        }
        XCTAssertEqual(listed.map(\.id), model.rows.map(\.id), "the list. \(context)")
        for (item, row) in zip(listed, model.rows) {
            let capture = row.capture
            XCTAssertEqual(item.hash, capture.hash, context)
            XCTAssertEqual(item.kind, capture.kind, context)
            XCTAssertEqual(item.title, capture.title, context)
            XCTAssertEqual(item.detail, capture.detail, context)
            XCTAssertEqual(item.preview, SearchModel.preview(of: capture.searchText), context)
            XCTAssertEqual(item.byteSize, row.byteSize, context)
            XCTAssertEqual(item.blobType, capture.blob?.type, context)
            XCTAssertEqual(item.fileCount, row.files.count, context)
            XCTAssertEqual(item.lastUsed.timeIntervalSince1970, row.lastUsed, context)
            XCTAssertEqual(item.isMissing, capture.kind == .file, context)
        }
        let count = try await store.count()
        XCTAssertEqual(count, model.rows.count, context)
        let used = try await store.storageUsage()
        XCTAssertEqual(used, model.storedBytes, "the byte counter. \(context)")
        if let budget = model.budget, model.rows.count > 1 {
            XCTAssertLessThanOrEqual(used - (model.rows.first?.storedBytes ?? 0), budget, context)
        }

        let files = FileManager.default
        let blobs = try files.contentsOfDirectory(atPath: store.location.blobs.path).sorted()
        XCTAssertEqual(blobs, model.rows.filter { $0.capture.blob != nil }.map(\.capture.hash).sorted(), "the blobs on disk. \(context)")
        let thumbs = try files.contentsOfDirectory(atPath: store.location.thumbs.path).sorted()
        let owners = model.rows.filter { $0.thumbnail != nil }
        XCTAssertEqual(thumbs, owners.map { "\($0.capture.hash).png" }.sorted(), "the thumbnails on disk. \(context)")
        for owner in owners {
            XCTAssertEqual(try Data(contentsOf: store.location.thumbnailURL(for: owner.capture.hash)), owner.thumbnail, context)
        }
        XCTAssertEqual(try files.contentsOfDirectory(atPath: store.location.staging.path), [], context)

        try StoreInspector.assertSound(at: store.location, context)
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM representations"), Int64(model.rows.reduce(0) { $0 + $1.representations.count }), context)
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM files"), Int64(model.rows.reduce(0) { $0 + $1.files.count }), context)

        var queries = ["u", "tmp txt", "image", "nul tail", "x"]
        for _ in 0..<8 {
            var words: [String] = []
            for _ in 0..<(random.chance(0.3) ? 2 : 1) {
                let word = random.pick(Self.vocabulary)
                let scalars = Array(word.unicodeScalars)
                words.append(String(String.UnicodeScalarView(scalars.prefix(Int.random(in: 1...scalars.count, using: &random)))))
            }
            queries.append(words.joined(separator: " "))
        }
        for (offset, query) in queries.enumerated() {
            let expected = model.rows.filter { SearchModel.matches($0.capture.searchText, query: query) }.map(\.id)
            let found = try await store.search(query, limit: 100_000).map(\.id)
            XCTAssertEqual(found, expected, "search for \(query.debugDescription). \(context)")
            guard offset % 4 == 0 else { continue }
            var paged: [Int64] = []
            var cursor: PageCursor?
            while true {
                let page = try await store.search(query, after: cursor, limit: 5)
                guard let last = page.last else { break }
                paged += page.map(\.id)
                cursor = PageCursor(after: last)
            }
            XCTAssertEqual(paged, expected, "paged search for \(query.debugDescription). \(context)")
        }

        for _ in 0..<min(4, model.rows.count) {
            let row = random.pick(model.rows)
            let fetched = try await store.payload(for: row.id)
            let payload = try XCTUnwrap(fetched, context)
            XCTAssertEqual(payload.kind, row.capture.kind, context)
            XCTAssertEqual(payload.plainText, row.capture.kind == .text && row.offersPlainText ? row.capture.searchText : nil, context)
            XCTAssertEqual(payload.representations, row.representations, context)
            XCTAssertEqual(payload.files, row.files, context)
            XCTAssertEqual(payload.blob, row.capture.blob, context)
            if row.capture.kind == .text {
                let preview = try await store.textPreview(for: row.id, maxCharacters: 50)
                XCTAssertEqual(preview, String(String.UnicodeScalarView(row.capture.searchText.unicodeScalars.prefix(50))), context)
            }
        }
    }
}

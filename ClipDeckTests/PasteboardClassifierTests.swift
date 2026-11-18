import XCTest
@testable import ClipDeck

final class PasteboardClassifierTests: XCTestCase {
    private let classifier = Fixtures.classifier()

    private func capture(_ items: [[String: Data]], using classifier: PasteboardClassifier? = nil) -> Capture? {
        guard case .capture(let capture) = (classifier ?? self.classifier).classify(Fixtures.snapshot(items)) else { return nil }
        return capture
    }

    // MARK: - Text

    func testPlainTextIsText() throws {
        let result = try XCTUnwrap(capture([[PasteboardTypes.plainText: Data("  hello\nworld".utf8)]]))
        XCTAssertEqual(result.kind, .text)
        XCTAssertEqual(result.title, "hello")
        XCTAssertEqual(result.searchText, "  hello\nworld")
        XCTAssertTrue(result.representations.isEmpty)
        XCTAssertTrue(result.offersPlainText)
        XCTAssertNil(result.blob)
    }

    func testTextHashIsStableAndContentBased() {
        let a = Fixtures.textCapture("same")
        let b = Fixtures.textCapture("same")
        let c = Fixtures.textCapture("different")
        XCTAssertEqual(a.hash, b.hash)
        XCTAssertNotEqual(a.hash, c.hash)
        XCTAssertEqual(a.hash.count, 64)
    }

    func testRichTextKeepsOriginalTypes() throws {
        let rtf = Data("{\\rtf1 bold}".utf8)
        let html = Data("<b>bold</b>".utf8)
        let result = try XCTUnwrap(capture([[
            PasteboardTypes.plainText: Data("bold".utf8),
            PasteboardTypes.rtf: rtf,
            PasteboardTypes.html: html,
            "dyn.ah62d4rv4gu8y": Data("ignored".utf8),
        ]]))
        XCTAssertEqual(result.kind, .text)
        XCTAssertEqual(Set(result.representations.map(\.type)), [PasteboardTypes.rtf, PasteboardTypes.html])
    }

    func testHTMLOnlyTextGetsPlainTextForSearch() throws {
        let result = try XCTUnwrap(capture([[PasteboardTypes.html: Data("<p>Hello &amp; <b>bye</b></p>".utf8)]]))
        XCTAssertEqual(result.kind, .text)
        XCTAssertEqual(result.searchText, "Hello & bye")
        XCTAssertFalse(result.offersPlainText)
    }

    func testWhitespaceOnlyTextIsSkipped() {
        let result = classifier.classify(Fixtures.snapshot([[PasteboardTypes.plainText: Data(" \n\t".utf8)]]))
        XCTAssertEqual(result, .skip(.empty))
    }

    func testTextOverCapIsSkipped() {
        let small = Fixtures.classifier(maxTextBytes: 10)
        let result = small.classify(Fixtures.snapshot([[PasteboardTypes.plainText: Data("eleven char".utf8)]]))
        XCTAssertEqual(result, .skip(.tooLarge(bytes: 11)))
    }

    func testRichPayloadsCountTowardTheCap() {
        let small = Fixtures.classifier(maxTextBytes: 10)
        let result = small.classify(Fixtures.snapshot([[
            PasteboardTypes.plainText: Data("short".utf8),
            PasteboardTypes.rtf: Data("{\\rtf1 x}".utf8),
        ]]))
        XCTAssertEqual(result, .skip(.tooLarge(bytes: 14)))
    }

    func testDefaultCapIsFiftyMegabytes() {
        XCTAssertEqual(Constants.Capture.maxTextBytes, 50 * 1024 * 1024)
        let oversized = Data(count: Constants.Capture.maxTextBytes + 1)
        let result = classifier.classify(Fixtures.snapshot([[PasteboardTypes.plainText: oversized]]))
        XCTAssertEqual(result, .skip(.tooLarge(bytes: Constants.Capture.maxTextBytes + 1)))
    }

    // MARK: - Titles and hashes

    /// Define a title by splitting the whole text into lines, selecting the first nonblank line,
    /// trimming it, and cutting it.
    private func referenceFirstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return String(line.prefix(200))
    }

    func testFirstLineMatchesTheReferenceOnEdgeCases() {
        let word = String(repeating: "x", count: 199)
        let cases: [String] = [
            "",
            " \n\t\r\n",
            "one",
            "  padded  ",
            "\n\n  second line  \nthird",
            "first\r\nsecond",
            "\u{2028}after a line separator\u{2029}next",
            "\u{85}after a next line\u{85}",
            "\u{0B}vertical tab\u{0C}form feed",
            "\u{A0}\u{3000}wide spaces\u{A0}",
            " \u{301}combining mark after a space",
            word + "    \nnext",
            word + "    more after the cut",
            word + String(repeating: " ", count: 5_000) + "\nnext",
            word + String(repeating: " ", count: 5_000) + "tail",
            String(repeating: "y", count: 10_000),
            String(repeating: "y", count: 150) + String(repeating: " ", count: 6_000),
            String(repeating: "y", count: 150) + String(repeating: " ", count: 6_000) + "z",
            String(repeating: " ", count: 6_000) + "after many spaces",
            String(repeating: "\n", count: 6_000) + "after many blank lines",
            String(repeating: "\u{1F1FA}\u{1F1F8}", count: 300),
            String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 250) + " end",
            "e" + String(repeating: "\u{301}", count: 5_000) + " zalgo\nnext",
            String(repeating: "a\u{301}", count: 2_047) + "b\u{301}\u{301}\u{301}" + String(repeating: "c", count: 300),
            String(repeating: "\u{1F468}\u{200D}\u{1F469}", count: 1_500),
            // The 200th character starts at the last scalar that the first pass reads.
            String(repeating: "a", count: 198) + "e" + String(repeating: "\u{301}", count: 3_896) + "b\u{301}\u{301}" + "ccc",
            String(repeating: "a", count: 198) + "e" + String(repeating: "\u{301}", count: 3_895) + "b\u{301}\u{301}" + "ccc",
            String(repeating: "a", count: 198) + "e" + String(repeating: "\u{301}", count: 3_897) + "b\u{301}\u{301}" + "ccc",
            String(repeating: "a", count: 199) + "e" + String(repeating: "\u{301}", count: 3_895) + "b\u{301}\u{301}" + "   ",
        ]
        for text in cases {
            XCTAssertEqual(PasteboardClassifier.firstLine(of: text), referenceFirstLine(of: text), "text of \(text.unicodeScalars.count) scalars")
        }
    }

    func testFirstLineMatchesTheReferenceOnGeneratedText() {
        let pieces = [
            " ", " ", "\t", "\n", "\r\n", "\u{2028}", "\u{85}", "\u{A0}", "a", "b", "word", "\u{E9}", "\u{301}",
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{1F1FA}", String(repeating: "q", count: 90),
            String(repeating: " ", count: 70),
        ]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        for _ in 0..<400 {
            let text = (0..<next(120)).map { _ in pieces[next(pieces.count)] }.joined()
            XCTAssertEqual(PasteboardClassifier.firstLine(of: text), referenceFirstLine(of: text))
        }
    }

    func testTextOfOnlySpacesAndLineBreaksIsSkipped() {
        for text in [" \u{A0}\u{2028}\u{85}\t\r\n", String(repeating: " \n", count: 10_000)] {
            let result = classifier.classify(Fixtures.snapshot([[PasteboardTypes.plainText: Data(text.utf8)]]))
            XCTAssertEqual(result, .skip(.empty))
        }
    }

    func testTextHashIsTheHashOfItsUTF8Bytes() {
        XCTAssertEqual(Fixtures.textCapture("same").hash, "63b8984c122c71449fa44964324ebe349cbba49db511ef5d589aadc3300c778c")
        XCTAssertEqual(
            Fixtures.textCapture("h\u{E9}llo \u{1F44B}").hash, "ea761eabc97c5f2bc30ee318a0ee148e4d1abf6ebaca39593b1534b76134e60f"
        )
        let bridged = NSString(string: "bridged \u{E9} text") as String
        let long = String(repeating: "long text \u{1F44B}\n", count: 50_000)
        for text in ["", "a", bridged, long, NSMutableString(string: long) as String] {
            XCTAssertEqual(PasteboardClassifier.hash(ofText: text), ContentHash.sha256(tag: "text", Data(text.utf8)))
        }
    }

    func testLargeTextKeepsItsTitleSizeAndSearchText() throws {
        let text = "\n  Title line  \n" + String(repeating: "body line\n", count: 200_000)
        let result = try XCTUnwrap(capture([[PasteboardTypes.plainText: Data(text.utf8)]]))
        XCTAssertEqual(result.title, "Title line")
        XCTAssertEqual(result.byteSize, Int64(text.utf8.count))
        XCTAssertEqual(result.searchText, text)
    }

    // MARK: - Files

    func testFileURLIsFileReference() throws {
        let result = Fixtures.fileCapture(["/Users/someone/Movies/clip.mov"])
        XCTAssertEqual(result.kind, .file)
        XCTAssertEqual(result.title, "clip.mov")
        XCTAssertEqual(result.detail, "/Users/someone/Movies/clip.mov")
        XCTAssertEqual(result.files, [FileReference(path: "/Users/someone/Movies/clip.mov", bookmark: Data("bookmark:/Users/someone/Movies/clip.mov".utf8))])
        XCTAssertNil(result.blob)
        XCTAssertTrue(result.representations.isEmpty)
    }

    func testFilesWinOverTheirNamesAsText() throws {
        let result = try XCTUnwrap(capture([[
            PasteboardTypes.fileURL: URL(fileURLWithPath: "/tmp/a.txt").dataRepresentation,
            PasteboardTypes.plainText: Data("a.txt".utf8),
        ]]))
        XCTAssertEqual(result.kind, .file)
    }

    func testFileHashIgnoresOrder() {
        let ab = Fixtures.fileCapture(["/tmp/a", "/tmp/b"])
        let ba = Fixtures.fileCapture(["/tmp/b", "/tmp/a"])
        XCTAssertEqual(ab.hash, ba.hash)
        XCTAssertEqual(ab.title, "a and 1 more")
        XCTAssertEqual(ab.byteSize, 20)
    }

    func testLargeSelectionKeepsPasteboardOrderAndSkipsWhatIsNotAFile() throws {
        let paths = (0..<600).map { "/Volumes/Media/clip \($0).mov" }
        var items = paths.map { [PasteboardTypes.fileURL: URL(fileURLWithPath: $0).dataRepresentation] }
        items.insert([PasteboardTypes.fileURL: Data("https://example.com/not-a-file".utf8)], at: 300)
        items.insert([PasteboardTypes.fileURL: Data([0xFF, 0xFE])], at: 0)
        let result = try XCTUnwrap(capture(items))
        XCTAssertEqual(result.files.map(\.path), paths)
        XCTAssertEqual(result.files.map(\.bookmark), paths.map { Data("bookmark:\($0)".utf8) })
        XCTAssertEqual(result.byteSize, 6_000)
        XCTAssertEqual(result.title, "clip 0.mov and 599 more")
        XCTAssertEqual(result.detail, paths[0])
        XCTAssertEqual(result.searchText, paths.joined(separator: "\n"))
    }

    func testOnlyURLsThatAreNotFilesIsEmpty() {
        let result = classifier.classify(Fixtures.snapshot([[PasteboardTypes.fileURL: Data("https://example.com/x".utf8)]]))
        XCTAssertEqual(result, .skip(.empty))
    }

    func testRealBookmarksAndSizesForManyFiles() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<64).map { index -> URL in
            let url = directory.appendingPathComponent("file \(index).txt")
            try Data(repeating: 0x61, count: index + 1).write(to: url)
            return url
        }
        let result = PasteboardClassifier().classify(Fixtures.snapshot(urls.map { [PasteboardTypes.fileURL: $0.dataRepresentation] }))
        guard case .capture(let capture) = result else { return XCTFail("files did not classify") }
        XCTAssertEqual(capture.files.map(\.path), urls.map(\.standardizedFileURL.path))
        XCTAssertEqual(capture.byteSize, Int64((1...64).reduce(0, +)))
        for (file, url) in zip(capture.files, urls) {
            let resolved = PasteboardWriter.resolve(file)
            XCTAssertNotNil(file.bookmark)
            XCTAssertEqual(resolved.resolvingSymlinksInPath().path, url.resolvingSymlinksInPath().path)
        }
    }

    func testFileSizeIsTheItemsOwnSize() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sized.bin")
        try Data(count: 1_234).write(to: file)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: file.path)

        XCTAssertEqual(PasteboardClassifier.size(ofFileAt: file.path), 1_234)
        XCTAssertEqual(PasteboardClassifier.size(ofFileAt: directory.appendingPathComponent("missing").path), 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(PasteboardClassifier.size(ofFileAt: link.path), (attributes[.size] as? NSNumber)?.int64Value)
        XCTAssertNotEqual(PasteboardClassifier.size(ofFileAt: link.path), 1_234)
    }

    // MARK: - Images and data

    func testPNGIsStoredAsIs() throws {
        let png = Fixtures.png(width: 8, height: 6)
        let result = try XCTUnwrap(capture([[PasteboardTypes.png: png, PasteboardTypes.html: Data("<img>".utf8)]]))
        XCTAssertEqual(result.kind, .image)
        XCTAssertEqual(result.blob, PasteboardRepresentation(type: PasteboardTypes.png, data: png))
        XCTAssertEqual(result.title, "Image 8\u{00D7}6")
    }

    func testTIFFIsConvertedToPNG() throws {
        let result = try XCTUnwrap(capture([[PasteboardTypes.tiff: Fixtures.tiff(width: 5, height: 5)]]))
        XCTAssertEqual(result.kind, .image)
        XCTAssertEqual(result.blob?.type, PasteboardTypes.png)
        let bytes = try XCTUnwrap(result.blob?.data.prefix(4))
        XCTAssertEqual(Array(bytes), [0x89, 0x50, 0x4E, 0x47])
    }

    func testImageKeepsCompanionTypes() throws {
        let png = Fixtures.png(width: 3, height: 3)
        let html = Data("<img src=x>".utf8)
        let source = Data("https://example.com/x.png".utf8)
        let result = try XCTUnwrap(capture([[
            PasteboardTypes.png: png,
            PasteboardTypes.html: html,
            "public.url": source,
            "dyn.ah62d4rv4gu8y": Data([1]),
        ]]))
        XCTAssertEqual(result.blob?.type, PasteboardTypes.png)
        XCTAssertEqual(Set(result.representations.map(\.type)), [PasteboardTypes.html, "public.url"])
        XCTAssertFalse(result.offersTIFF)
    }

    func testTIFFAlongsidePNGIsFlaggedNotStored() throws {
        let result = try XCTUnwrap(capture([[
            PasteboardTypes.png: Fixtures.png(width: 3, height: 3),
            PasteboardTypes.tiff: Fixtures.tiff(width: 3, height: 3),
        ]]))
        XCTAssertTrue(result.offersTIFF)
        XCTAssertFalse(result.representations.contains { $0.type == PasteboardTypes.tiff })
    }

    func testConvertedTIFFIsFlagged() throws {
        let result = try XCTUnwrap(capture([[PasteboardTypes.tiff: Fixtures.tiff(width: 5, height: 5)]]))
        XCTAssertTrue(result.offersTIFF)
    }

    func testCompanionsOverTheCapAreDroppedButTheImageIsKept() throws {
        let png = Fixtures.png(width: 2, height: 2)
        let result = try XCTUnwrap(capture(
            [[PasteboardTypes.png: png, PasteboardTypes.html: Data(repeating: 0x41, count: 64)]],
            using: Fixtures.classifier(maxTextBytes: 16)
        ))
        XCTAssertEqual(result.blob?.data, png)
        XCTAssertTrue(result.representations.isEmpty)
    }

    func testBinaryKeepsCompanionTypes() throws {
        let result = try XCTUnwrap(capture([[
            "com.example.custom-data": Data([1, 2]),
            "com.example.other": Data([3]),
        ]]))
        XCTAssertEqual(result.blob?.type, "com.example.custom-data")
        XCTAssertEqual(result.representations, [PasteboardRepresentation(type: "com.example.other", data: Data([3]))])
    }

    func testPlainTextBeatsAnAttachedImage() throws {
        let result = try XCTUnwrap(capture([[
            PasteboardTypes.plainText: Data("caption".utf8),
            PasteboardTypes.png: Fixtures.png(width: 2, height: 2),
        ]]))
        XCTAssertEqual(result.kind, .text)
    }

    func testOtherBinaryIsStoredAsBlob() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let result = try XCTUnwrap(capture([["com.example.custom-data": payload]]))
        XCTAssertEqual(result.kind, .image)
        XCTAssertEqual(result.blob, PasteboardRepresentation(type: "com.example.custom-data", data: payload))
    }

    // MARK: - Skipped pasteboards

    func testConcealedIsSkipped() {
        let result = classifier.classify(Fixtures.snapshot([[
            PasteboardTypes.plainText: Data("hunter2".utf8),
            PasteboardTypes.concealed: Data(),
        ]]))
        XCTAssertEqual(result, .skip(.concealed))
    }

    func testTransientIsSkipped() {
        let result = classifier.classify(Fixtures.snapshot([[
            PasteboardTypes.plainText: Data("one time code".utf8),
            PasteboardTypes.transient: Data(),
        ]]))
        XCTAssertEqual(result, .skip(.transient))
    }

    func testMarkerOnAnyItemSkipsTheWholePasteboard() {
        let result = classifier.classify(Fixtures.snapshot([
            [PasteboardTypes.plainText: Data("visible".utf8)],
            [PasteboardTypes.concealed: Data()],
        ]))
        XCTAssertEqual(result, .skip(.concealed))
    }

    func testEmptyPasteboardIsSkipped() {
        XCTAssertEqual(classifier.classify(Fixtures.snapshot([])), .skip(.empty))
    }
}

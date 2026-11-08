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

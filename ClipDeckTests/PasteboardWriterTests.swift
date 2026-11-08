import AppKit
import XCTest
@testable import ClipDeck

final class PasteboardWriterTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipDeckTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    private func types() -> Set<String> {
        Set((pasteboard.pasteboardItems?.first?.types ?? []).map(\.rawValue))
    }

    func testTextComesBackWithEveryOriginalType() {
        let rtf = Data("{\\rtf1 rich}".utf8)
        let html = Data("<b>rich</b>".utf8)
        let payload = ClipPayload(
            kind: .text,
            plainText: "rich",
            representations: [
                PasteboardRepresentation(type: PasteboardTypes.rtf, data: rtf),
                PasteboardRepresentation(type: PasteboardTypes.html, data: html),
            ],
            files: [],
            blob: nil
        )
        XCTAssertNotNil(PasteboardWriter.write(payload, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "rich")
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtf)
        XCTAssertEqual(pasteboard.data(forType: .html), html)
    }

    func testTextWithoutOriginalPlainTextIsWrittenWithoutIt() {
        let html = Data("<b>rich</b>".utf8)
        let payload = ClipPayload(
            kind: .text,
            plainText: nil,
            representations: [PasteboardRepresentation(type: PasteboardTypes.html, data: html)],
            files: [],
            blob: nil
        )
        XCTAssertNotNil(PasteboardWriter.write(payload, to: pasteboard))
        XCTAssertEqual(types(), [PasteboardTypes.html])
    }

    func testWriteReturnsTheChangeCountItProduced() {
        let payload = ClipPayload(kind: .text, plainText: "count", representations: [], files: [], blob: nil)
        let before = pasteboard.changeCount
        let changeCount = PasteboardWriter.write(payload, to: pasteboard)
        XCTAssertEqual(changeCount, pasteboard.changeCount)
        XCTAssertNotEqual(changeCount, before)
    }

    func testImageComesBackWithBlobAndCompanions() {
        let png = Fixtures.png(width: 3, height: 2)
        let tiff = Fixtures.tiff(width: 3, height: 2)
        let source = Data("https://example.com/x.png".utf8)
        let payload = ClipPayload(
            kind: .image,
            plainText: nil,
            representations: [
                PasteboardRepresentation(type: PasteboardTypes.tiff, data: tiff),
                PasteboardRepresentation(type: "public.url", data: source),
            ],
            files: [],
            blob: PasteboardRepresentation(type: PasteboardTypes.png, data: png)
        )
        XCTAssertNotNil(PasteboardWriter.write(payload, to: pasteboard))
        XCTAssertEqual(pasteboard.data(forType: .png), png)
        XCTAssertEqual(pasteboard.data(forType: .tiff), tiff)
        XCTAssertEqual(pasteboard.data(forType: NSPasteboard.PasteboardType("public.url")), source)
    }

    func testImageWithoutBlobWritesNothing() {
        pasteboard.clearContents()
        pasteboard.setString("untouched", forType: .string)
        let payload = ClipPayload(kind: .image, plainText: nil, representations: [], files: [], blob: nil)
        XCTAssertNil(PasteboardWriter.write(payload, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
    }

    func testCapturedImageRoundTripsThroughTheClassifier() throws {
        let png = Fixtures.png(width: 5, height: 5)
        let html = Data("<img>".utf8)
        guard case .capture(let capture) = Fixtures.classifier().classify(
            Fixtures.snapshot([[PasteboardTypes.png: png, PasteboardTypes.html: html]])
        ) else { return XCTFail("image did not classify") }
        let payload = ClipPayload(
            kind: capture.kind, plainText: nil, representations: capture.representations, files: [], blob: capture.blob
        )
        XCTAssertNotNil(PasteboardWriter.write(payload, to: pasteboard))
        XCTAssertEqual(types(), [PasteboardTypes.png, PasteboardTypes.html])
        XCTAssertEqual(pasteboard.data(forType: .png), png)
    }

    func testExistingFileIsWrittenAsFileURL() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("present.txt")
        try Data("x".utf8).write(to: file)

        let payload = ClipPayload(
            kind: .file, plainText: nil, representations: [],
            files: [FileReference(path: file.path, bookmark: nil)], blob: nil
        )
        XCTAssertNotNil(PasteboardWriter.write(payload, to: pasteboard))
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        XCTAssertEqual(urls?.map(\.standardizedFileURL.path), [file.standardizedFileURL.path])
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testMissingFileIsWrittenWithItsPathAsText() {
        let path = "/nonexistent/\(UUID().uuidString)/gone.mov"
        let payload = ClipPayload(
            kind: .file, plainText: nil, representations: [],
            files: [FileReference(path: path, bookmark: nil)], blob: nil
        )
        XCTAssertNotNil(PasteboardWriter.write(payload, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), path)
        XCTAssertTrue(types().contains(PasteboardTypes.fileURL))
    }
}

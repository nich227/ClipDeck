import XCTest
@testable import ClipDeck

final class MenuFormattingTests: XCTestCase {
    private func item(
        kind: ClipKind, title: String, preview: String = "", detail: String? = nil, isMissing: Bool = false
    ) -> ClipItem {
        ClipItem(
            id: 1, hash: "h", kind: kind, createdAt: Date(), lastUsed: Date(), title: title, detail: detail,
            preview: preview, byteSize: 0, blobType: nil, fileCount: kind == .file ? 1 : 0, isMissing: isMissing
        )
    }

    func testTextTitleIsOneLineWithCollapsedWhitespace() {
        let text = item(kind: .text, title: "first\tline  of\n\nthe copy")
        XCTAssertEqual(MenuFormatting.title(for: text), "first line of the copy")
    }

    func testLongTitlesAreCutWithAnEllipsis() {
        let long = String(repeating: "x", count: 200)
        let title = MenuFormatting.title(for: item(kind: .text, title: long))
        XCTAssertEqual(title.count, Constants.Menu.titleCharacters)
        XCTAssertTrue(title.hasSuffix("\u{2026}"))
    }

    func testShortTitlesAreNotCut() {
        XCTAssertEqual(MenuFormatting.title(for: item(kind: .text, title: "short")), "short")
    }

    func testWhitespaceOnlyTextGetsAName() {
        XCTAssertEqual(MenuFormatting.title(for: item(kind: .text, title: "   ", preview: "  \n ")), "Blank Text")
    }

    func testEmptyTitleFallsBackToThePreview() {
        XCTAssertEqual(MenuFormatting.title(for: item(kind: .text, title: "", preview: "from the preview")), "from the preview")
    }

    func testMissingFilesSaySo() {
        let file = item(kind: .file, title: "report.pdf", detail: "/Users/me/report.pdf", isMissing: true)
        XCTAssertEqual(MenuFormatting.title(for: file), "report.pdf (Not Found)")
    }

    func testTooltips() {
        let file = item(kind: .file, title: "report.pdf", detail: "/Users/me/report.pdf")
        XCTAssertEqual(MenuFormatting.tooltip(for: file), "/Users/me/report.pdf")
        XCTAssertNil(MenuFormatting.tooltip(for: item(kind: .image, title: "Image 4\u{00D7}3")))
        let short = item(kind: .text, title: "short", preview: "short")
        XCTAssertNil(MenuFormatting.tooltip(for: short), "no tooltip when the title already shows everything")
        let long = String(repeating: "word ", count: 40)
        XCTAssertEqual(MenuFormatting.tooltip(for: item(kind: .text, title: long, preview: long)), long.trimmingCharacters(in: .whitespaces))
    }
}

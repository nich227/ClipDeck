import SwiftUI
import XCTest
@testable import ClipDeck

final class ItemFormattingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(
        kind: ClipKind, title: String, detail: String? = nil, byteSize: Int64 = 0, blobType: String? = nil,
        fileCount: Int = 0, isMissing: Bool = false, age: TimeInterval = 3_600
    ) -> ClipItem {
        ClipItem(
            id: 1, hash: "h", kind: kind, createdAt: now.addingTimeInterval(-age), lastUsed: now.addingTimeInterval(-age),
            title: title, detail: detail, preview: title, byteSize: byteSize, blobType: blobType, fileCount: fileCount,
            isMissing: isMissing
        )
    }

    func testAnItemCopiedInTheLastMinuteIsJustNow() {
        XCTAssertEqual(ItemFormatting.relativeTime(now.addingTimeInterval(-5), now: now), "just now")
        XCTAssertEqual(ItemFormatting.relativeTime(now.addingTimeInterval(-59), now: now), "just now")
        XCTAssertEqual(ItemFormatting.relativeTime(now.addingTimeInterval(30), now: now), "just now", "a clock that moved back")
    }

    func testOlderItemsUseARelativeTime() {
        let time = ItemFormatting.relativeTime(now.addingTimeInterval(-7_200), now: now)
        XCTAssertNotEqual(time, "just now")
        XCTAssertTrue(time.contains("2"), time)
    }

    func testTextSubtitleNamesTheKind() {
        let subtitle = ItemFormatting.subtitle(for: item(kind: .text, title: "hello", age: 10), now: now)
        XCTAssertEqual(subtitle, ItemFormatting.Subtitle(detail: "Text", time: "just now"))
    }

    func testImageSubtitleHasTheTypeAndTheSize() {
        let image = item(kind: .image, title: "Image 4\u{00D7}3", byteSize: 2_000_000, blobType: PasteboardTypes.png, age: 10)
        XCTAssertEqual(ItemFormatting.subtitle(for: image, now: now).detail, "PNG \u{00B7} 2 MB")
    }

    func testFileSubtitleAbbreviatesTheHomeFolder() {
        let path = NSHomeDirectory() + "/Documents/report.pdf"
        let file = item(kind: .file, title: "report.pdf", detail: path, fileCount: 1)
        XCTAssertEqual(ItemFormatting.subtitle(for: file, now: now).detail, "~/Documents/report.pdf")
        XCTAssertEqual(ItemFormatting.abbreviatedPath(nil), "")
    }

    func testMetadataCountsFiles() {
        XCTAssertEqual(ItemFormatting.metadata(for: item(kind: .file, title: "a", byteSize: 1_000, fileCount: 1)), "1 file \u{00B7} 1 KB")
        XCTAssertEqual(ItemFormatting.metadata(for: item(kind: .file, title: "a", byteSize: 1_000, fileCount: 3)), "3 files \u{00B7} 1 KB")
        XCTAssertEqual(ItemFormatting.metadata(for: item(kind: .text, title: "a", byteSize: 1_000)), "Text \u{00B7} 1 KB")
    }

    func testUnknownBinaryTypesAreData() {
        XCTAssertEqual(ItemFormatting.typeName("com.example.custom"), "Data")
        XCTAssertEqual(ItemFormatting.typeName("public.jpeg"), "JPEG")
    }

    func testSpokenDescriptionReadsTheTitleThenTheStateThenTheSubtitle() {
        let missing = item(kind: .file, title: "report.pdf", detail: "/tmp/report.pdf", fileCount: 1, isMissing: true, age: 10)
        XCTAssertEqual(
            ItemFormatting.spokenDescription(for: missing, now: now),
            "report.pdf, Not Found, /tmp/report.pdf, just now"
        )
        let text = item(kind: .text, title: "hello", age: 10)
        XCTAssertEqual(ItemFormatting.spokenDescription(for: text, now: now), "hello, Text, just now")
        // A row builds its subtitle once and says the same words.
        let subtitle = ItemFormatting.subtitle(for: missing, now: now)
        XCTAssertEqual(
            ItemFormatting.spokenDescription(for: missing, subtitle: subtitle),
            ItemFormatting.spokenDescription(for: missing, now: now)
        )
    }

    func testSurfaceFillsAreStrongerWithIncreaseContrast() {
        for fill in [Palette.surface1, Palette.surface2, Palette.hairline] {
            XCTAssertGreaterThan(fill.opacity(for: .increased), fill.opacity(for: .standard))
        }
        XCTAssertEqual(Palette.surface2.opacity(for: .standard), 0.11)
        XCTAssertEqual(Palette.clear.opacity(for: .increased), 0)
    }
}

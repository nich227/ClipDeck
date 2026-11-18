import XCTest
@testable import ClipDeck

final class ContentHashTests: XCTestCase {
    /// These values identify stored rows, so the encoding must never change.
    func testHashIsLowercaseHexOfTagSeparatorAndBytes() {
        XCTAssertEqual(
            ContentHash.sha256(tag: "text", Data("hello".utf8)),
            "306f89347195cc05509ddca47462e259aac6fd01943d2557004ea6f26370cd58"
        )
        XCTAssertEqual(
            ContentHash.sha256(tag: "image", Data(0...255)),
            "9530724d64f6aba9a54a6bdc025fb9a8ebb81573bf02eb17b4a271d9883475a1"
        )
        XCTAssertEqual(
            ContentHash.sha256(tag: "data:public.jpeg", Data()),
            "891a6c00133c1e46e086b767f70ec114c6c0ef73ef1afb1d1c7620216e449492"
        )
    }

    func testTagKeepsEqualBytesApart() {
        let bytes = Data("same".utf8)
        XCTAssertNotEqual(ContentHash.sha256(tag: "text", bytes), ContentHash.sha256(tag: "file", bytes))
    }

    func testSlicedDataHashesItsOwnBytes() {
        let whole = Data("xxhelloxx".utf8)
        XCTAssertEqual(ContentHash.sha256(tag: "text", whole[2..<7]), ContentHash.sha256(tag: "text", Data("hello".utf8)))
    }
}

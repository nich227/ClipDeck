import XCTest
@testable import ClipDeck

final class ListMetricsTests: XCTestCase {
    private let viewport: CGFloat = 364

    func testAnEmptyListHasNoHeightAndNoRows() {
        XCTAssertEqual(ListMetrics.contentHeight(count: 0), 0)
        XCTAssertEqual(ListMetrics.window(offset: 0, viewport: viewport, count: 0), 0..<0)
    }

    func testContentHeightCountsEveryRowOnceAndTheInsetTwice() {
        XCTAssertEqual(ListMetrics.contentHeight(count: 1), 2 * ListMetrics.inset + ListMetrics.rowHeight)
        XCTAssertEqual(
            ListMetrics.contentHeight(count: 10_000),
            2 * ListMetrics.inset + 10_000 * ListMetrics.pitch - ListMetrics.spacing
        )
    }

    func testTheWindowAtTheTopStartsAtTheFirstRow() {
        let window = ListMetrics.window(offset: 0, viewport: viewport, count: 10_000, overscan: 4)
        XCTAssertEqual(window.lowerBound, 0)
        let lastVisible = Int((viewport - ListMetrics.inset) / ListMetrics.pitch)
        XCTAssertEqual(window.upperBound, lastVisible + 4 + 1)
    }

    func testTheWindowSizeDoesNotGrowWithTheItemCount() {
        let deep = ListMetrics.top(of: 7_500)
        let small = ListMetrics.window(offset: 0, viewport: viewport, count: 20)
        let large = ListMetrics.window(offset: deep, viewport: viewport, count: 10_000)
        XCTAssertLessThanOrEqual(small.count, 20)
        XCTAssertLessThanOrEqual(large.count, Int(viewport / ListMetrics.pitch) + 2 * Constants.Panel.rowOverscan + 2)
        XCTAssertTrue(large.contains(7_500))
    }

    func testTheWindowStaysInsideTheListWhenScrolledPastTheEnd() {
        let window = ListMetrics.window(offset: 1_000_000, viewport: viewport, count: 50)
        XCTAssertEqual(window, 49..<50)
        let above = ListMetrics.window(offset: -500, viewport: viewport, count: 50, overscan: 0)
        XCTAssertEqual(above.lowerBound, 0)
    }

    func testEveryRowThatIntersectsTheViewportIsInTheWindow() {
        for offset in stride(from: CGFloat(0), through: 3_000, by: 7) {
            let window = ListMetrics.window(offset: offset, viewport: viewport, count: 200, overscan: 0)
            for index in 0..<200 {
                let top = ListMetrics.top(of: index)
                let intersects = top < offset + viewport && top + ListMetrics.rowHeight > offset
                if intersects { XCTAssertTrue(window.contains(index), "row \(index) at offset \(offset)") }
            }
        }
    }

    func testAVisibleRowNeedsNoScroll() {
        XCTAssertNil(ListMetrics.offset(revealing: 2, from: 0, viewport: viewport, count: 100))
    }

    func testARowBelowScrollsJustFarEnoughToShowItsLowerEdge() throws {
        let index = 30
        let target = try XCTUnwrap(ListMetrics.offset(revealing: index, from: 0, viewport: viewport, count: 100))
        XCTAssertEqual(target + viewport, ListMetrics.top(of: index) + ListMetrics.rowHeight + ListMetrics.inset)
        XCTAssertNil(ListMetrics.offset(revealing: index, from: target, viewport: viewport, count: 100))
    }

    func testARowAboveScrollsJustFarEnoughToShowItsUpperEdge() throws {
        let target = try XCTUnwrap(ListMetrics.offset(revealing: 10, from: 2_000, viewport: viewport, count: 100))
        XCTAssertEqual(target, ListMetrics.top(of: 10) - ListMetrics.inset)
        XCTAssertNil(ListMetrics.offset(revealing: 10, from: target, viewport: viewport, count: 100))
    }

    func testTheFirstAndLastRowsScrollToTheEnds() throws {
        XCTAssertEqual(ListMetrics.offset(revealing: 0, from: 900, viewport: viewport, count: 100), 0)
        let last = try XCTUnwrap(ListMetrics.offset(revealing: 99, from: 0, viewport: viewport, count: 100))
        XCTAssertEqual(last, ListMetrics.contentHeight(count: 100) - viewport)
    }

    func testAnOutOfRangeRowNeedsNoScroll() {
        XCTAssertNil(ListMetrics.offset(revealing: -1, from: 0, viewport: viewport, count: 10))
        XCTAssertNil(ListMetrics.offset(revealing: 10, from: 0, viewport: viewport, count: 10))
    }

    func testOneArrowKeyStepMovesTheListByAtMostOneRow() throws {
        var offset: CGFloat = 0
        for index in 0..<500 {
            if let target = ListMetrics.offset(revealing: index, from: offset, viewport: viewport, count: 500) {
                XCTAssertLessThanOrEqual(abs(target - offset), ListMetrics.pitch + ListMetrics.inset)
                offset = target
            }
        }
        XCTAssertEqual(offset, ListMetrics.contentHeight(count: 500) - viewport)
    }
}

import XCTest
@testable import ClipDeck

@MainActor
final class PanelPlacementTests: XCTestCase {
    private let size = NSSize(width: Constants.Panel.width, height: Constants.Panel.height)

    func testThePanelIsCenteredWithRoomAboveItOnALargeScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1728, height: 1079)
        let frame = PanelController.frame(in: visible)
        XCTAssertEqual(frame.size, size)
        XCTAssertEqual(frame.midX, visible.midX)
        XCTAssertEqual(visible.maxY - frame.maxY, visible.height * Constants.Panel.topInset, accuracy: 0.001)
    }

    func testThePanelFollowsASecondScreensOrigin() {
        let visible = NSRect(x: -1920, y: 300, width: 1920, height: 1055)
        let frame = PanelController.frame(in: visible)
        XCTAssertTrue(visible.contains(frame))
        XCTAssertEqual(frame.midX, visible.midX)
    }

    func testThePanelStaysOnAScreenShorterThanItsPreferredPlace() {
        let visible = NSRect(x: 0, y: 40, width: 1024, height: 500)
        let frame = PanelController.frame(in: visible)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY)
    }

    func testOnAScreenSmallerThanThePanelTheSearchFieldStaysVisible() {
        let visible = NSRect(x: 100, y: 50, width: 600, height: 400)
        let frame = PanelController.frame(in: visible)
        XCTAssertEqual(frame.minX, visible.minX)
        XCTAssertEqual(frame.maxY, visible.maxY)
    }
}

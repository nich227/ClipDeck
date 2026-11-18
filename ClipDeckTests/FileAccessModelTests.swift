import XCTest
@testable import ClipDeck

@MainActor
final class FileAccessModelTests: XCTestCase {
    func testAnAccessAlreadyGrantedWhenTheWindowOpensIsNotJustGranted() {
        let model = FileAccessModel()
        model.apply([.desktop: .granted, .documents: .undetermined])
        XCTAssertEqual(model.states[.desktop], .granted)
        XCTAssertTrue(model.justGranted.isEmpty, "the first state of an access is not a change")
    }

    func testAGrantAfterAKnownStateIsJustGranted() {
        let model = FileAccessModel()
        model.apply([.desktop: .undetermined, .documents: .denied])
        model.apply([.desktop: .granted])
        XCTAssertEqual(model.justGranted, [.desktop])
        model.apply([.documents: .granted])
        XCTAssertEqual(model.justGranted, [.desktop, .documents], "a later grant joins the earlier one")
    }

    func testAStateThatStaysGrantedIsNotGrantedAgain() {
        let model = FileAccessModel()
        model.apply([.desktop: .granted])
        model.apply([.desktop: .granted])
        XCTAssertTrue(model.justGranted.isEmpty)
    }

    func testSeveralGrantsInOneRefreshShowStill() {
        let model = FileAccessModel()
        model.apply([.desktop: .undetermined, .documents: .undetermined, .downloads: .undetermined])
        model.apply([.desktop: .granted, .documents: .granted, .downloads: .undetermined])
        XCTAssertEqual(model.states[.desktop], .granted)
        XCTAssertEqual(model.states[.documents], .granted)
        XCTAssertTrue(model.justGranted.isEmpty, "one mark moves at a time")
    }

    func testALostGrantCanBeGrantedAgain() {
        let model = FileAccessModel()
        model.apply([.fullDisk: .denied])
        model.apply([.fullDisk: .granted])
        XCTAssertEqual(model.justGranted, [.fullDisk])
        model.apply([.fullDisk: .denied])
        XCTAssertTrue(model.justGranted.isEmpty)
        model.apply([.fullDisk: .granted])
        XCTAssertEqual(model.justGranted, [.fullDisk])
    }

    func testAGrantMadeWhileTheWindowWasClosedShowsStillWhenItReopens() {
        let model = FileAccessModel()
        model.windowWillOpen(isFirstLaunch: true)
        model.record([.desktop: .undetermined, .fullDisk: .denied])
        model.record([.desktop: .granted, .fullDisk: .denied])
        XCTAssertEqual(model.justGranted, [.desktop], "a grant in the open window draws on")

        model.windowWillOpen(isFirstLaunch: false)
        XCTAssertTrue(model.justGranted.isEmpty, "a mark that drew on does not draw again")
        XCTAssertFalse(model.isFirstLaunch)
        model.record([.desktop: .granted, .fullDisk: .granted])
        XCTAssertEqual(model.states[.fullDisk], .granted)
        XCTAssertTrue(model.justGranted.isEmpty, "the state was already true when the window opened")

        model.record([.desktop: .granted, .fullDisk: .denied])
        model.record([.desktop: .granted, .fullDisk: .granted])
        XCTAssertEqual(model.justGranted, [.fullDisk], "a grant after the window opened draws on")
    }

    func testAllFoldersGrantedIgnoresFullDiskAccess() {
        let model = FileAccessModel()
        model.apply([.desktop: .granted, .documents: .granted, .downloads: .granted, .removableVolumes: .granted, .fullDisk: .denied])
        XCTAssertTrue(model.allFoldersGranted)
        model.apply([.downloads: .denied])
        XCTAssertFalse(model.allFoldersGranted)
    }
}

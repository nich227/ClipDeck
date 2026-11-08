import AppKit
import XCTest
@testable import ClipDeck

final class PasteboardMonitorTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var monitor: PasteboardMonitor!
    private let captures = CaptureLog()

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipDeckTests-\(UUID().uuidString)"))
        let log = captures
        monitor = PasteboardMonitor(pasteboard: pasteboard) { log.append($0) }
    }

    override func tearDown() {
        monitor.stop()
        pasteboard.releaseGlobally()
    }

    /// It is long enough for several polls to run.
    private func waitForPolls() {
        let settled = expectation(description: "polls ran")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
    }

    func testOwnWriteIsNotCapturedButOutsideWriteIs() {
        monitor.start()
        waitForPolls()

        let written = monitor.writeOwn { pasteboard in
            let changeCount = pasteboard.clearContents()
            return pasteboard.setString("written by clipdeck", forType: .string) ? changeCount : nil
        }
        XCTAssertTrue(written)
        waitForPolls()
        XCTAssertTrue(captures.all.isEmpty)

        pasteboard.clearContents()
        pasteboard.setString("written by someone else", forType: .string)
        waitForPolls()
        XCTAssertEqual(captures.all.map(\.searchText), ["written by someone else"])
    }

    func testWhatIsOnThePasteboardAtStartIsNotCaptured() {
        pasteboard.clearContents()
        pasteboard.setString("already here", forType: .string)
        monitor.start()
        waitForPolls()
        XCTAssertTrue(captures.all.isEmpty)
    }

    func testPausedMonitorDoesNotCapture() {
        monitor.start()
        waitForPolls()
        monitor.pause(.screenLocked)
        pasteboard.clearContents()
        pasteboard.setString("while locked", forType: .string)
        waitForPolls()
        XCTAssertTrue(captures.all.isEmpty)

        monitor.resume(.screenLocked)
        waitForPolls()
        XCTAssertEqual(captures.all.map(\.searchText), ["while locked"])
    }
}

/// Captures are collected from the monitor's queue.
private final class CaptureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [Capture] = []

    func append(_ capture: Capture) {
        lock.lock()
        captures.append(capture)
        lock.unlock()
    }

    var all: [Capture] {
        lock.lock()
        defer { lock.unlock() }
        return captures
    }
}

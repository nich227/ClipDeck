import XCTest
@testable import ClipDeck

final class ClearPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCutoffs() {
        XCTAssertEqual(ClearRange.lastHour.cutoff(now: now), now.addingTimeInterval(-3_600))
        XCTAssertEqual(ClearRange.last24Hours.cutoff(now: now), now.addingTimeInterval(-86_400))
        XCTAssertEqual(ClearRange.last7Days.cutoff(now: now), now.addingTimeInterval(-604_800))
        XCTAssertEqual(ClearRange.last4Weeks.cutoff(now: now), now.addingTimeInterval(-2_419_200))
        XCTAssertNil(ClearRange.allTime.cutoff(now: now))
    }

    func testRangesAreOrderedFromShortestToAllTime() {
        let intervals = ClearRange.allCases.compactMap(\.interval)
        XCTAssertEqual(intervals, intervals.sorted())
        XCTAssertEqual(ClearRange.allCases.last, .allTime)
    }

    func testTitles() {
        XCTAssertEqual(ClearRange.allCases.map(\.title), [
            "the last hour", "the last 24 hours", "the last 7 days", "the last 4 weeks", "all history",
        ])
    }

    func testRequestUsesItsOwnClock() {
        let request = ClearRequest(range: .last24Hours, kinds: [.text], now: now)
        XCTAssertEqual(request.cutoff, now.addingTimeInterval(-86_400))
        XCTAssertFalse(request.isEmpty)
        XCTAssertTrue(ClearRequest(range: .allTime, kinds: [], now: now).isEmpty)
    }
}

final class PollingGateTests: XCTestCase {
    func testGateOpensOnlyWhenEveryReasonClears() {
        var gate = PollingGate()
        XCTAssertTrue(gate.isOpen)
        XCTAssertTrue(gate.pause(.screenLocked))
        XCTAssertFalse(gate.pause(.systemAsleep))
        XCTAssertFalse(gate.resume(.systemAsleep))
        XCTAssertFalse(gate.isOpen)
        XCTAssertTrue(gate.resume(.screenLocked))
        XCTAssertTrue(gate.isOpen)
    }

    func testResumingAnUnpausedReasonChangesNothing() {
        var gate = PollingGate()
        XCTAssertFalse(gate.resume(.screensAsleep))
        XCTAssertTrue(gate.isOpen)
    }
}

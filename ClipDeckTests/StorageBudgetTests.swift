import XCTest
@testable import ClipDeck

final class StorageBudgetTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ClipDeckTests.StorageBudget.\(UUID().uuidString)"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testNoLimitUntilTurnedOn() {
        XCTAssertNil(StorageBudget.load(from: defaults))
        defaults.set(12.0, forKey: Constants.Storage.limitGigabytesKey)
        XCTAssertNil(StorageBudget.load(from: defaults), "a saved number without the toggle is not a limit")
    }

    func testTurnedOnWithoutANumberUsesTheDefault() {
        defaults.set(true, forKey: Constants.Storage.limitEnabledKey)
        XCTAssertEqual(StorageBudget.load(from: defaults)?.gigabytes, Constants.Storage.defaultLimitGigabytes)
    }

    func testGigabytesAreDecimalLikeFinder() {
        XCTAssertEqual(StorageBudget(gigabytes: 2.5).bytes, 2_500_000_000)
    }

    func testOutOfRangeValuesAreClamped() {
        XCTAssertEqual(StorageBudget(gigabytes: 0).gigabytes, Constants.Storage.minimumLimitGigabytes)
        XCTAssertEqual(StorageBudget(gigabytes: -4).gigabytes, Constants.Storage.minimumLimitGigabytes)
        XCTAssertEqual(StorageBudget(gigabytes: 1e9).gigabytes, Constants.Storage.maximumLimitGigabytes)
        XCTAssertEqual(StorageBudget(gigabytes: .nan).gigabytes, Constants.Storage.defaultLimitGigabytes)
    }

    // MARK: - Eviction plan

    private let oldestFirst = [
        EvictionCandidate(id: 1, hash: "a", bytes: 100),
        EvictionCandidate(id: 2, hash: "b", bytes: 300),
        EvictionCandidate(id: 3, hash: "c", bytes: 50),
        EvictionCandidate(id: 4, hash: "d", bytes: 1000),
    ]

    func testPicksOldestUntilTheExcessIsFreed() {
        let picked = EvictionPlan.select(from: oldestFirst, excess: 120, keeping: 4)
        XCTAssertEqual(picked.map(\.id), [1, 2], "100 is not enough, 400 is")
    }

    func testExactFitStopsEarly() {
        let picked = EvictionPlan.select(from: oldestFirst, excess: 100, keeping: 4)
        XCTAssertEqual(picked.map(\.id), [1])
    }

    func testNeverPicksTheNewestRow() {
        let picked = EvictionPlan.select(from: oldestFirst, excess: 10_000, keeping: 4)
        XCTAssertEqual(picked.map(\.id), [1, 2, 3])
    }

    func testNewestRowIsSkippedWhereverItSits() {
        let picked = EvictionPlan.select(from: oldestFirst, excess: 120, keeping: 1)
        XCTAssertEqual(picked.map(\.id), [2])
    }

    func testNothingToFreeMeansNothingPicked() {
        XCTAssertEqual(EvictionPlan.select(from: oldestFirst, excess: 0, keeping: 4), [])
        XCTAssertEqual(EvictionPlan.select(from: oldestFirst, excess: -5, keeping: 4), [])
        XCTAssertEqual(EvictionPlan.select(from: [], excess: 5, keeping: 4), [])
    }
}

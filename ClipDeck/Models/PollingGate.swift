import Foundation

/// An active reason pauses capture. Polling runs only when no reason is active, so a wake while the
/// screen is still locked does not restart polling.
struct PauseReasons: OptionSet, Sendable {
    let rawValue: Int

    static let screenLocked = PauseReasons(rawValue: 1 << 0)
    static let systemAsleep = PauseReasons(rawValue: 1 << 1)
    static let screensAsleep = PauseReasons(rawValue: 1 << 2)
    static let sessionInactive = PauseReasons(rawValue: 1 << 3)
}

struct PollingGate: Equatable, Sendable {
    private(set) var reasons: PauseReasons = []

    var isOpen: Bool { reasons.isEmpty }

    /// Returns true when the gate changes between open and closed.
    @discardableResult
    mutating func pause(_ reason: PauseReasons) -> Bool {
        let wasOpen = isOpen
        reasons.insert(reason)
        return wasOpen != isOpen
    }

    @discardableResult
    mutating func resume(_ reason: PauseReasons) -> Bool {
        let wasOpen = isOpen
        reasons.remove(reason)
        return wasOpen != isOpen
    }
}

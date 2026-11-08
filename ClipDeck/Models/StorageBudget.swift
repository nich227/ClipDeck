import Foundation

/// This setting controls how much content the history may hold before removing the oldest items.
/// The setting is off unless the user turns it on in Settings.
struct StorageBudget: Equatable, Sendable {
    /// This constant uses decimal gigabytes, the unit Finder and `ByteCountFormatter` report.
    static let bytesPerGigabyte: Int64 = 1_000_000_000

    let gigabytes: Double

    init(gigabytes: Double) {
        self.gigabytes = Self.clamp(gigabytes)
    }

    var bytes: Int64 { Int64(gigabytes * Double(Self.bytesPerGigabyte)) }

    static func clamp(_ gigabytes: Double) -> Double {
        guard gigabytes.isFinite else { return Constants.Storage.defaultLimitGigabytes }
        return min(max(gigabytes, Constants.Storage.minimumLimitGigabytes), Constants.Storage.maximumLimitGigabytes)
    }

    /// This is the saved limit, or nil when no limit is enabled.
    static func load(from defaults: UserDefaults) -> StorageBudget? {
        guard defaults.bool(forKey: Constants.Storage.limitEnabledKey) else { return nil }
        let saved = defaults.object(forKey: Constants.Storage.limitGigabytesKey) as? Double
        return StorageBudget(gigabytes: saved ?? Constants.Storage.defaultLimitGigabytes)
    }
}

/// This identifies a row that the store may remove and gives the number of bytes that the row
/// holds.
struct EvictionCandidate: Equatable, Sendable {
    let id: Int64
    let hash: String
    let bytes: Int64
}

enum EvictionPlan {
    /// Selects enough rows for removal to free at least `excess` bytes. `candidates` must list the
    /// oldest rows first. The newest row is never selected, so the latest copy survives even when
    /// it alone exceeds the limit.
    static func select(from candidates: [EvictionCandidate], excess: Int64, keeping newestID: Int64) -> [EvictionCandidate] {
        guard excess > 0 else { return [] }
        var freed: Int64 = 0
        var picked: [EvictionCandidate] = []
        for candidate in candidates where candidate.id != newestID {
            if freed >= excess { break }
            picked.append(candidate)
            freed += candidate.bytes
        }
        return picked
    }
}

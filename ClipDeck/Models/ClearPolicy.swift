import Foundation

/// The Clear History sheet offers these ranges.
enum ClearRange: String, CaseIterable, Identifiable, Sendable {
    case lastHour
    case last24Hours
    case last7Days
    case last4Weeks
    case allTime

    var id: Self { self }

    var title: String {
        switch self {
        case .lastHour: return "the last hour"
        case .last24Hours: return "the last 24 hours"
        case .last7Days: return "the last 7 days"
        case .last4Weeks: return "the last 4 weeks"
        case .allTime: return "all history"
        }
    }

    /// The range extends back by this amount. Nil means there is no limit.
    var interval: TimeInterval? {
        switch self {
        case .lastHour: return 60 * 60
        case .last24Hours: return 24 * 60 * 60
        case .last7Days: return 7 * 24 * 60 * 60
        case .last4Weeks: return 28 * 24 * 60 * 60
        case .allTime: return nil
        }
    }

    /// The range includes items last copied at or after this time.
    func cutoff(now: Date) -> Date? {
        interval.map { now.addingTimeInterval(-$0) }
    }
}

struct ClearRequest: Equatable, Sendable {
    let range: ClearRange
    let kinds: Set<ClipKind>
    let now: Date

    init(range: ClearRange, kinds: Set<ClipKind>, now: Date = Date()) {
        self.range = range
        self.kinds = kinds
        self.now = now
    }

    var cutoff: Date? { range.cutoff(now: now) }

    var isEmpty: Bool { kinds.isEmpty }
}

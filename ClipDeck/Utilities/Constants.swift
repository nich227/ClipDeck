import SwiftUI

enum Constants {
    static let appName = "ClipDeck"
    static let logSubsystem = "com.kevster.clipdeck"
    static let showMenuBarIconKey = "showMenuBarIcon"
    static let showCopyConfirmationKey = "showCopyConfirmation"
    static let welcomeShownKey = "welcomeShown"
    static let hotkeyKey = "hotkey"
    static let repository = "https://github.com/nich227/ClipDeck"

    enum Brand {
        /// Resources/Fonts contains the wordmark font, and ATSApplicationFontsPath registers it.
        static let fontName = "InstrumentSerif-Regular"
    }
    static let supportDirectoryName = "ClipDeck"
    static let databaseFileName = "clipdeck.sqlite"

    enum Capture {
        static let pollInterval: DispatchTimeInterval = .milliseconds(300)
        static let pollLeeway: DispatchTimeInterval = .milliseconds(50)
        static let maxTextBytes = 50 * 1024 * 1024
    }

    enum List {
        static let pageSize = 100
        static let searchDebounce: Duration = .milliseconds(80)
        static let rowPreviewCharacters = 300
        static let detailPreviewCharacters = 4_000
        static let loadMoreThreshold = 20
        static let minimumSearchLength = 2
    }

    enum Thumbnail {
        static let maxPixelSize = 512
        static let pointSize = CGSize(width: 256, height: 256)
        static let scale: CGFloat = 2
    }

    enum Storage {
        static let limitEnabledKey = "storageLimitEnabled"
        static let limitGigabytesKey = "storageLimitGigabytes"
        static let defaultLimitGigabytes: Double = 5
        static let minimumLimitGigabytes: Double = 1
        static let maximumLimitGigabytes: Double = 10_000
        /// This value sets the number of rows removed per eviction transaction, so reads interleave
        /// with a long eviction.
        static let evictionBatch = 256
        /// The system checks this many files per transaction while sweeping orphans after a crash.
        static let sweepBatch = 500
        /// A series of stepper clicks or typed digits can settle before the limit applies.
        static let limitApplyDebounce: Duration = .milliseconds(600)
    }

    enum Menu {
        static let recentCount = 10
        static let titleCharacters = 60
        static let iconSide: CGFloat = 20
        /// Key equivalents for the recent rows, in row order: Command-1 through Command-9, then
        /// Command-0 for the tenth, the way Safari numbers its tabs.
        static let rowKeys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    }

    enum Panel {
        static let width: CGFloat = 720
        static let height: CGFloat = 460
        /// This is the fraction of the visible screen height remaining above the panel.
        static let topInset: CGFloat = 0.14
        static let previewWidth: CGFloat = 260
    }

    /// The confirmation moves down from the top of the screen after copying.
    enum HUD {
        static let width: CGFloat = 280
        static let height: CGFloat = 52
        /// This is the gap between the menu bar and the pill, measured in points.
        static let topGap: CGFloat = 10
        static let dwell: Duration = .milliseconds(1400)
        static let checkSide: CGFloat = 28
    }

    enum Animations {
        static let paperclip = "paperclip"
        static let copied = "copied"
    }
}

/// The panel is Liquid Glass, so its color tokens follow the system appearance and the wallpaper
/// behind it. Use color only as a signal.
enum Palette {
    /// ClipDeck uses the accent the user picked in System Settings. It has no color of its own.
    static let accent = Color.accentColor
    static let accentSoft = Color.accentColor.opacity(0.12)
    static let caution = Color("ClipDeckCaution")
    static let danger = Color("ClipDeckDanger")

    /// The fills sit on the glass for hover, selection, thumbnail wells, and key hints. They use
    /// the label color, so they darken light glass and lighten dark glass.
    static let surface1 = Color.primary.opacity(0.06)
    static let surface2 = Color.primary.opacity(0.11)
    static let hairline = Color.primary.opacity(0.10)

    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
}

/// Use one spacing ramp: 4, 8, 12, 16, 20, 24, 32, 40.
enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 40
}

/// The radius ramp uses 4, 8, 12, and 20.
enum Radius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 20
}

enum Anim {
    /// Use ease-micro for presses and quick state changes.
    static let quick: Animation = .easeOut(duration: 0.2)
    /// Use ease-out and cubic-bezier(0.16, 1, 0.3, 1) for entrances and reveals.
    static let standard: Animation = .timingCurve(0.16, 1, 0.3, 1, duration: 0.35)
    static let entrance: Animation = .timingCurve(0.16, 1, 0.3, 1, duration: 0.8)

    /// Returns nil when Reduce Motion is on, so the change applies without animating.
    static func allowed(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// Use each type role from the shared scale with its own tracking. Differentiate the roles by
/// opacity first, then by size. Apply each type role and its tracking with `deckFont(_:)`.
enum DeckType {
    /// Only the app's name uses the wordmark face.
    case wordmark
    case title
    /// The panel's search field uses Title size and regular weight.
    case search
    case body
    case label
    case caption
    case mono

    var font: Font {
        switch self {
        case .wordmark: return .custom(Constants.Brand.fontName, size: 34)
        case .title: return .system(size: 20, weight: .semibold)
        case .search: return .system(size: 20, weight: .regular)
        case .body: return .system(size: 15, weight: .regular)
        case .label: return .system(size: 13, weight: .medium)
        case .caption: return .system(size: 11, weight: .light)
        case .mono: return .system(size: 12, weight: .regular, design: .monospaced)
        }
    }

    var tracking: CGFloat {
        switch self {
        case .wordmark, .title, .search: return 0
        case .body: return 0.35
        case .label: return 0.3
        case .caption, .mono: return 0.5
        }
    }
}

extension View {
    func deckFont(_ role: DeckType) -> some View {
        font(role.font).tracking(role.tracking)
    }
}

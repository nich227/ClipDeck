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
        /// The panel and menu keep at most this many bytes of decoded thumbnails in memory.
        static let cacheCostLimit = 64 * 1024 * 1024
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
        /// The sweep checks this many files per transaction when it removes orphaned files after a
        /// crash.
        static let sweepBatch = 500
        /// SQLite copies the write-ahead log into the database after this many pages. Each copy
        /// waits for the disk twice.
        static let checkpointPages = 4_000
        /// The write-ahead log file keeps this many bytes between checkpoints. The value covers
        /// `checkpointPages` pages and their frame headers.
        static let logSizeLimit = 20 * 1024 * 1024
        /// A series of stepper clicks or typed digits can settle before the limit applies.
        static let limitApplyDebounce: Duration = .milliseconds(600)
    }

    enum Menu {
        static let recentCount = 10
        static let titleCharacters = 60
        static let iconSide = Glyph.row
        /// The longest side of a row thumbnail, in pixels, fits the icon on a display at three
        /// times scale and leaves room to crop it to a square.
        static let iconPixelSize = 128
        /// The menu keeps at most this many file type icons between openings.
        static let typeIconLimit = 64
        /// The recent rows use Command-1 through Command-9 as key equivalents in row order, then
        /// Command-0 for the tenth row.
        static let rowKeys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    }

    enum Panel {
        static let width: CGFloat = 720
        /// There is enough space for `visibleRows` whole rows between the search field and the
        /// footer.
        static let height: CGFloat = 470
        static let visibleRows = 7
        /// This is the fraction of the visible screen height remaining above the panel.
        static let topInset: CGFloat = 0.14
        static let previewWidth: CGFloat = 260
        /// Every row has this height, so the list can place a row without measuring it.
        static let rowHeight: CGFloat = 48
        static let rowThumbnailSide: CGFloat = 32
        /// A row and a menu item draw the same small bitmap, so the cache holds one for both.
        static let rowThumbnailPixelSize = Menu.iconPixelSize
        /// The file preview's artwork and the inline video share this height.
        static let previewArtworkHeight: CGFloat = 160
        static let selectionBar = CGSize(width: 2, height: 16)
        /// A missing item's thumbnail and artwork are dimmed beside a message that says the item is
        /// missing.
        static let missingItemOpacity = 0.5
        /// Rows remain alive above and below the visible rows.
        static let rowOverscan = 4
        /// A selected item must stay selected this long before its full text or video loads. This
        /// delay keeps holding an arrow key from starting a load for each row.
        static let previewSettle: Duration = .milliseconds(120)
    }

    /// The confirmation moves down from the top of the screen after copying.
    enum HUD {
        static let width: CGFloat = 280
        static let height: CGFloat = 52
        /// This is the gap between the menu bar and the pill, measured in points.
        static let topGap: CGFloat = 10
        static let dwell: Duration = .milliseconds(1400)
        static let checkSide = Glyph.state
        /// The window stays open this long after the pill starts to leave so that the spring can
        /// finish.
        static let orderOutDelay: Duration = .milliseconds(500)
    }

    /// The files in Resources/Animations are listed by name. `scripts/make-animations.py` writes
    /// them.
    enum Animations {
        /// When played once, the empty history loop draws the paperclip and holds it.
        static let paperclip = "paperclip"
        /// The done mark shows a ring, then a check.
        static let copied = "copied"
        static let granted = copied
        /// A magnifying glass indicates that a search found nothing.
        static let noResults = "noresults"
        static let all = [paperclip, copied, noResults]
        /// Each file marks the frame to show when motion is not allowed. A one-shot stops on that
        /// frame.
        static let stillMarker = "reduced motion"
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
    /// the label color, so they darken light glass and lighten dark glass. Each one is stronger
    /// when Increase Contrast is on.
    static let surface1 = SurfaceFill(opacity: 0.06, increasedContrastOpacity: 0.12)
    static let surface2 = SurfaceFill(opacity: 0.11, increasedContrastOpacity: 0.22)
    static let hairline = SurfaceFill(opacity: 0.10, increasedContrastOpacity: 0.40)
    static let clear = SurfaceFill(opacity: 0, increasedContrastOpacity: 0)

    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
}

/// The Increase Contrast setting controls the label color fill's opacity.
struct SurfaceFill: ShapeStyle, Equatable {
    let opacity: Double
    let increasedContrastOpacity: Double

    func opacity(for contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? increasedContrastOpacity : opacity
    }

    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        Color.primary.opacity(opacity(for: environment.colorSchemeContrast))
    }
}

/// Use one spacing ramp: 2, 4, 8, 12, 16, 20, 24, 32, 40. The first step only sets a title on the
/// line it describes.
enum Space {
    static let xxxs: CGFloat = 2
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

/// Symbols and marks use one size ramp: 16, 20, 28, 44, 72.
enum Glyph {
    /// A symbol appears on a line of text, such as the search glyph.
    static let inline: CGFloat = 16
    /// A symbol or thumbnail for a row outside the panel, such as a menu row's icon.
    static let row: CGFloat = 20
    /// The symbol appears in an empty or failed state, or in an empty artwork well. The check
    /// appears in the copy confirmation.
    static let state: CGFloat = 28
    /// About and Welcome show the paperclip mark.
    static let mark: CGFloat = 44
    /// A drawn animation uses this frame size. A file type icon in the preview uses it too.
    static let illustration: CGFloat = 72
}

enum Anim {
    /// Use ease-micro for presses and quick state changes.
    static let quick: Animation = .easeOut(duration: 0.2)
    /// Use ease-out and cubic-bezier(0.16, 1, 0.3, 1) for entrances and reveals.
    static let standard: Animation = .timingCurve(0.16, 1, 0.3, 1, duration: 0.35)
    static let entrance: Animation = .timingCurve(0.16, 1, 0.3, 1, duration: 0.8)

    /// This returns nil when Reduce Motion is on, so the change applies without animating.
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
        case .caption: return .system(size: 11, weight: .regular)
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

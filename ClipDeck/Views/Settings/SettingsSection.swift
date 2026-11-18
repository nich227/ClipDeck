import SwiftUI

/// The toolbar shows the Settings panes in the same order as the cases.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case history
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .history: return "History"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }

    /// Every pane has the same width. Each pane is as tall as its content, and the window animates
    /// to that height when the tab changes or a row appears.
    static let width: CGFloat = 560
    /// This is the maximum width of a centered line of text in About and Welcome.
    static let textMeasure: CGFloat = 440
}

extension View {
    /// The Settings pane uses a grouped form with switch toggles and is sized to its content.
    func settingsPane() -> some View {
        self
            .formStyle(.grouped)
            .toggleStyle(.switch)
            .frame(width: SettingsSection.width)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A form row label contains the setting and one optional line that explains what the setting does.
struct SettingLabel: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxxs) {
            Text(title)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

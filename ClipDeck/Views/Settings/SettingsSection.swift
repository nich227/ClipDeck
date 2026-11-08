import SwiftUI

/// The Settings panes follow the toolbar order.
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

    /// One width for every pane; the height is the pane's own, and the window animates between
    /// them when the tab changes.
    static let width: CGFloat = 560

    var height: CGFloat {
        switch self {
        case .general: return 500
        case .history: return 600
        case .about: return 420
        }
    }

    var size: CGSize { CGSize(width: Self.width, height: height) }
}

extension View {
    /// The Settings pane uses a shared frame with a grouped form and switch toggles.
    func settingsPane(_ section: SettingsSection) -> some View {
        self
            .formStyle(.grouped)
            .toggleStyle(.switch)
            .frame(width: SettingsSection.width, height: section.height)
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
        VStack(alignment: .leading, spacing: 2) {
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

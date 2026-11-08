import Foundation

/// Give each row in the menu that opens from the menu bar a one-line title. Keep each title short
/// enough for the menu to fit on the screen.
enum MenuFormatting {
    static func title(for item: ClipItem, maxCharacters: Int = Constants.Menu.titleCharacters) -> String {
        let base: String
        switch item.kind {
        case .text:
            let line = collapseWhitespace(item.title.isEmpty ? item.preview : item.title)
            base = line.isEmpty ? "Blank Text" : line
        case .image, .file:
            base = collapseWhitespace(item.title)
        }
        let shortened = truncate(base, to: maxCharacters)
        return item.isMissing ? "\(shortened) (Not Found)" : shortened
    }

    /// Hover over the row to see the file's path or any text that does not fit in the title.
    static func tooltip(for item: ClipItem) -> String? {
        switch item.kind {
        case .file:
            return item.detail
        case .text:
            let preview = item.preview.trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.count > title(for: item).count ? preview : nil
        case .image:
            return nil
        }
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func truncate(_ text: String, to maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(max(maxCharacters - 1, 0))) + "\u{2026}"
    }
}

import Foundation

/// This builds the text that the panel shows for an item. It includes the line under the title, the
/// metadata, and the sentence VoiceOver says for the row.
enum ItemFormatting {
    struct Subtitle: Equatable {
        /// A narrow row truncates the kind, the size, or the file's path.
        let detail: String
        /// The time since the item was last copied always shows in full.
        let time: String
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    /// `RelativeDateTimeFormatter` counts seconds for an item less than a minute old, which reads
    /// as noise. This function skips the formatter and says that the item is new.
    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        return relative.localizedString(for: date, relativeTo: now)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func subtitle(for item: ClipItem, now: Date = Date()) -> Subtitle {
        let time = relativeTime(item.lastUsed, now: now)
        switch item.kind {
        case .text:
            return Subtitle(detail: "Text", time: time)
        case .image:
            return Subtitle(detail: "\(typeName(item.blobType)) \u{00B7} \(size(item.byteSize))", time: time)
        case .file:
            return Subtitle(detail: abbreviatedPath(item.detail), time: time)
        }
    }

    /// The preview's first metadata line.
    static func metadata(for item: ClipItem) -> String {
        switch item.kind {
        case .text:
            return "Text \u{00B7} \(size(item.byteSize))"
        case .image:
            return "\(typeName(item.blobType)) \u{00B7} \(size(item.byteSize))"
        case .file:
            let count = item.fileCount == 1 ? "1 file" : "\(item.fileCount.formatted()) files"
            return "\(count) \u{00B7} \(size(item.byteSize))"
        }
    }

    /// For VoiceOver, use one sentence with the title, whether the item is missing, and then the
    /// subtitle.
    static func spokenDescription(for item: ClipItem, now: Date = Date()) -> String {
        spokenDescription(for: item, subtitle: subtitle(for: item, now: now))
    }

    /// Builds the same sentence as `spokenDescription(for:now:)` using a subtitle that the caller
    /// already built.
    static func spokenDescription(for item: ClipItem, subtitle: Subtitle) -> String {
        var parts = [item.title]
        if item.isMissing { parts.append("Not Found") }
        parts.append(subtitle.detail)
        parts.append(subtitle.time)
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func abbreviatedPath(_ path: String?) -> String {
        (path as NSString?)?.abbreviatingWithTildeInPath ?? ""
    }

    static func typeName(_ type: String?) -> String {
        switch type {
        case PasteboardTypes.png: return "PNG"
        case PasteboardTypes.tiff: return "TIFF"
        case "public.jpeg": return "JPEG"
        case "public.heic": return "HEIC"
        case "com.compuserve.gif": return "GIF"
        default: return "Data"
        }
    }
}

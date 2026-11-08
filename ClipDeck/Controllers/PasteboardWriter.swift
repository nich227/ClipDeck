import AppKit

/// Restores a stored item to a pasteboard with the same types used when it was copied.
enum PasteboardWriter {
    /// Returns the change count the write produced, or nil when nothing was written.
    @discardableResult
    static func write(_ payload: ClipPayload, to pasteboard: NSPasteboard) -> Int? {
        switch payload.kind {
        case .text:
            let item = NSPasteboardItem()
            if let text = payload.plainText {
                item.setString(text, forType: .string)
            }
            for representation in payload.representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return replaceContents(of: pasteboard, with: [item])

        case .image:
            guard let blob = payload.blob else {
                Log.panel.error("Blob for the selected item is missing")
                return nil
            }
            let item = NSPasteboardItem()
            item.setData(blob.data, forType: NSPasteboard.PasteboardType(blob.type))
            for representation in payload.representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return replaceContents(of: pasteboard, with: [item])

        case .file:
            let urls = payload.files.map(resolve)
            guard let firstURL = urls.first else { return nil }
            let items = urls.map { url -> NSPasteboardItem in
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                return item
            }
            // You can still paste a missing file using its path.
            if urls.contains(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
                items.first?.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Log.panel.debug("Writing \(urls.count) file references starting with \(firstURL.lastPathComponent, privacy: .private)")
            return replaceContents(of: pasteboard, with: items)
        }
    }

    private static func replaceContents(of pasteboard: NSPasteboard, with items: [NSPasteboardItem]) -> Int? {
        let changeCount = pasteboard.clearContents()
        return pasteboard.writeObjects(items) ? changeCount : nil
    }

    /// It follows the bookmark when the file has moved since it was copied.
    static func resolve(_ file: FileReference) -> URL {
        if let bookmark = file.bookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return URL(fileURLWithPath: file.path)
    }
}

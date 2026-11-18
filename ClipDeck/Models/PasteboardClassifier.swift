import AppKit

enum SkipReason: Equatable, Sendable {
    case empty
    case concealed
    case transient
    case tooLarge(bytes: Int)
}

enum Classification: Equatable {
    case capture(Capture)
    case skip(SkipReason)
}

/// This determines the type of pasteboard content and what to keep.
///
/// Order matters. File URLs take priority because Finder also puts the file names on the pasteboard
/// as text. Plain text takes priority over images because rich text editors attach a picture of the
/// selection. An image with no plain text remains an image, even when a browser adds HTML.
struct PasteboardClassifier {
    var maxTextBytes = Constants.Capture.maxTextBytes
    var makeBookmark: (URL) -> Data? = PasteboardClassifier.bookmark(for:)
    var fileSize: (String) -> Int64 = PasteboardClassifier.size(ofFileAt:)
    var convertToPNG: (Data) -> Data? = ImageProcessing.pngData(from:)

    func classify(_ snapshot: PasteboardSnapshot) -> Classification {
        let types = snapshot.allTypes
        if types.contains(PasteboardTypes.concealed) { return .skip(.concealed) }
        if types.contains(PasteboardTypes.transient) { return .skip(.transient) }
        guard let first = snapshot.items.first else { return .skip(.empty) }

        let fileItems = snapshot.items.filter { $0.types.contains(PasteboardTypes.fileURL) }
        if !fileItems.isEmpty { return classifyFiles(fileItems) }
        if first.types.contains(PasteboardTypes.plainText) { return classifyText(first) }
        if let image = classifyImage(first) { return image }
        if first.types.contains(PasteboardTypes.rtf) || first.types.contains(PasteboardTypes.html) {
            return classifyText(first)
        }
        return classifyBinary(first)
    }

    // MARK: - Files

    private func classifyFiles(_ items: [PasteboardSnapshot.Item]) -> Classification {
        let files = references(from: items.compactMap { $0.data(PasteboardTypes.fileURL) })
        let paths = files.map(\.reference.path)
        guard let firstPath = paths.first else { return .skip(.empty) }

        let canonical = paths.sorted().joined(separator: "\n")
        let firstName = (firstPath as NSString).lastPathComponent
        let title = paths.count == 1 ? firstName : "\(firstName) and \(paths.count - 1) more"
        return .capture(Capture(
            kind: .file,
            hash: ContentHash.sha256(tag: "file", Data(canonical.utf8)),
            title: title,
            detail: firstPath,
            searchText: paths.joined(separator: "\n"),
            byteSize: files.reduce(0) { $0 + $1.size },
            representations: [],
            offersPlainText: false,
            files: files.map(\.reference),
            blob: nil,
            offersTIFF: false
        ))
    }

    private struct SizedReference {
        let reference: FileReference
        let size: Int64
    }

    /// A path, a bookmark, and a size cost several system calls per file, so a large selection
    /// spreads them over the cores. `makeBookmark` and `fileSize` must be safe to call from several
    /// threads at once. The result keeps the pasteboard order and leaves out anything that is not a
    /// file URL.
    private func references(from payloads: [Data]) -> [SizedReference] {
        var slots = [SizedReference?](repeating: nil, count: payloads.count)
        slots.withUnsafeMutableBufferPointer { slots in
            // Each iteration writes only its own slot.
            DispatchQueue.concurrentPerform(iterations: payloads.count) { index in
                guard let url = URL(dataRepresentation: payloads[index], relativeTo: nil), url.isFileURL else { return }
                let path = url.standardizedFileURL.path
                slots[index] = SizedReference(
                    reference: FileReference(path: path, bookmark: makeBookmark(URL(fileURLWithPath: path))),
                    size: fileSize(path)
                )
            }
        }
        return slots.compactMap { $0 }
    }

    // MARK: - Text

    private func classifyText(_ item: PasteboardSnapshot.Item) -> Classification {
        var total = 0
        var plain: String?
        if let data = item.data(PasteboardTypes.plainText) {
            total += data.count
            guard total <= maxTextBytes else { return .skip(.tooLarge(bytes: total)) }
            plain = String(data: data, encoding: .utf8)
        }

        var representations: [PasteboardRepresentation] = []
        for type in item.types where Self.isStorableType(type) && type != PasteboardTypes.plainText {
            guard let data = item.data(type) else { continue }
            total += data.count
            guard total <= maxTextBytes else { return .skip(.tooLarge(bytes: total)) }
            representations.append(PasteboardRepresentation(type: type, data: data))
        }

        let offersPlainText = plain != nil
        if plain == nil {
            plain = Self.plainText(fromRepresentations: representations)
        }
        guard let text = plain else { return .skip(.empty) }
        let title = Self.firstLine(of: text)
        // A text with no first line is only spaces and line breaks.
        guard !title.isEmpty else { return .skip(.empty) }

        return .capture(Capture(
            kind: .text,
            hash: Self.hash(ofText: text),
            title: title,
            detail: nil,
            searchText: text,
            byteSize: Int64(total),
            representations: representations,
            offersPlainText: offersPlainText,
            files: [],
            blob: nil,
            offersTIFF: false
        ))
    }

    /// It hashes the text's existing UTF-8 bytes, so it does not copy a large text only to hash it.
    static func hash(ofText text: String) -> String {
        var text = text
        return text.withUTF8 { buffer in
            guard let base = buffer.baseAddress else { return ContentHash.sha256(tag: "text", Data()) }
            let bytes = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: buffer.count, deallocator: .none)
            return ContentHash.sha256(tag: "text", bytes)
        }
    }

    private static func plainText(fromRepresentations representations: [PasteboardRepresentation]) -> String? {
        if let rtf = representations.first(where: { $0.type == PasteboardTypes.rtf }),
           let string = NSAttributedString(rtf: rtf.data, documentAttributes: nil)?.string {
            return string
        }
        // HTML import needs the main thread, so this code strips tags by hand.
        if let html = representations.first(where: { $0.type == PasteboardTypes.html }),
           let source = String(data: html.data, encoding: .utf8) {
            return source
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// The first line that contains a non-space character is trimmed and cut to `titleCharacters`.
    /// The result is empty when the text contains only spaces and line breaks. The work stops at
    /// the end of that line or shortly after the cut, whichever comes first. Thus, the cost does
    /// not grow with the text.
    static func firstLine(of text: String) -> String {
        let scalars = text.unicodeScalars
        guard let start = scalars.firstIndex(where: { !isLineBreak($0) && !isSpace($0) }) else { return "" }

        var end = start
        var scanned = 0
        while end < scalars.endIndex, scanned < titleWindow, !isLineBreak(scalars[end]) {
            scalars.formIndex(after: &end)
            scanned += 1
        }
        let head = String(scalars[start..<end])
        let lineEndsInWindow = end == scalars.endIndex || isLineBreak(scalars[end])
        if lineEndsInWindow {
            return String(trimmingTrailingSpaces(head).prefix(titleCharacters))
        }

        // The window may end inside a character, so the cut is safe only when a whole character
        // follows it.
        if head.count > titleCharacters {
            let cut = head.index(head.startIndex, offsetBy: titleCharacters)
            let title = String(head[..<cut])
            let lineContinues = head[cut...].unicodeScalars.contains { !isSpace($0) } || hasTextBeforeLineBreak(scalars[end...])
            return lineContinues ? title : trimmingTrailingSpaces(title)
        }

        let lineEnd = scalars[end...].firstIndex(where: isLineBreak) ?? scalars.endIndex
        return String(trimmingTrailingSpaces(String(scalars[start..<lineEnd])).prefix(titleCharacters))
    }

    private static let titleCharacters = 200
    /// The value is the number of scalars `firstLine(of:)` reads before it looks for the cut.
    private static let titleWindow = 4_096

    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A...0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x20 || scalar.value == 0x09 || (scalar.value > 0x7F && CharacterSet.whitespaces.contains(scalar))
    }

    private static func hasTextBeforeLineBreak(_ scalars: Substring.UnicodeScalarView) -> Bool {
        for scalar in scalars {
            if isLineBreak(scalar) { return false }
            if !isSpace(scalar) { return true }
        }
        return false
    }

    private static func trimmingTrailingSpaces(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let last = scalars.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(scalars[...last])
    }

    // MARK: - Images and other data

    private func classifyImage(_ item: PasteboardSnapshot.Item) -> Classification? {
        let offersTIFF = item.types.contains(PasteboardTypes.tiff)
        if let png = item.data(PasteboardTypes.png) {
            return imageCapture(png, type: PasteboardTypes.png, item: item, offersTIFF: offersTIFF)
        }
        if offersTIFF, let tiff = item.data(PasteboardTypes.tiff) {
            if let png = convertToPNG(tiff) {
                return imageCapture(png, type: PasteboardTypes.png, item: item, offersTIFF: true)
            }
            return imageCapture(tiff, type: PasteboardTypes.tiff, item: item, offersTIFF: false)
        }
        for type in PasteboardTypes.otherImages where item.types.contains(type) {
            if let data = item.data(type) { return imageCapture(data, type: type, item: item, offersTIFF: false) }
        }
        return nil
    }

    private func imageCapture(_ data: Data, type: String, item: PasteboardSnapshot.Item, offersTIFF: Bool) -> Classification {
        guard !data.isEmpty else { return .skip(.empty) }
        let title = ImageProcessing.pixelSize(of: data)
            .map { "Image \(Int($0.width))\u{00D7}\(Int($0.height))" } ?? "Image"
        return .capture(Capture(
            kind: .image,
            hash: ContentHash.sha256(tag: "image", data),
            title: title,
            detail: nil,
            searchText: title,
            byteSize: Int64(data.count),
            representations: companions(of: item, excluding: [type, PasteboardTypes.tiff]),
            offersPlainText: false,
            files: [],
            blob: PasteboardRepresentation(type: type, data: data),
            offersTIFF: offersTIFF
        ))
    }

    private func classifyBinary(_ item: PasteboardSnapshot.Item) -> Classification {
        for type in item.types where Self.isStorableType(type) {
            guard let data = item.data(type), !data.isEmpty else { continue }
            let title = "Data (\(type))"
            return .capture(Capture(
                kind: .image,
                hash: ContentHash.sha256(tag: "data:\(type)", data),
                title: title,
                detail: nil,
                searchText: title,
                byteSize: Int64(data.count),
                representations: companions(of: item, excluding: [type]),
                offersPlainText: false,
                files: [],
                blob: PasteboardRepresentation(type: type, data: data),
                offersTIFF: false
            ))
        }
        return .skip(.empty)
    }

    /// Returns the item's other payloads in pasteboard order. They include the HTML and source URL
    /// that a browser adds next to an image. The size cap excludes any payload that would take the
    /// total past the cap, but it never excludes the main payload.
    private func companions(of item: PasteboardSnapshot.Item, excluding excluded: Set<String>) -> [PasteboardRepresentation] {
        var total = 0
        var kept: [PasteboardRepresentation] = []
        for type in item.types where Self.isStorableType(type) && !excluded.contains(type) {
            guard let data = item.data(type), !data.isEmpty, total + data.count <= maxTextBytes else { continue }
            total += data.count
            kept.append(PasteboardRepresentation(type: type, data: data))
        }
        return kept
    }

    /// Dynamic types and the pasteboard's own bookkeeping types contain no data that we need to
    /// keep.
    private static func isStorableType(_ type: String) -> Bool {
        !type.hasPrefix("dyn.") && !type.hasPrefix("com.apple.pasteboard.") && !type.hasPrefix("org.nspasteboard.")
    }

    // MARK: - Defaults

    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// This is the size of the item itself. A symbolic link is not followed. A missing item has
    /// size 0.
    static func size(ofFileAt path: String) -> Int64 {
        var info = stat()
        return lstat(path, &info) == 0 ? Int64(info.st_size) : 0
    }
}

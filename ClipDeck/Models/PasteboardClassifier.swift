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
        let paths = items.compactMap { item -> String? in
            guard let data = item.data(PasteboardTypes.fileURL),
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.isFileURL else { return nil }
            return url.standardizedFileURL.path
        }
        guard let firstPath = paths.first else { return .skip(.empty) }

        let files = paths.map { FileReference(path: $0, bookmark: makeBookmark(URL(fileURLWithPath: $0))) }
        let canonical = paths.sorted().joined(separator: "\n")
        let firstName = (firstPath as NSString).lastPathComponent
        let title = paths.count == 1 ? firstName : "\(firstName) and \(paths.count - 1) more"
        return .capture(Capture(
            kind: .file,
            hash: ContentHash.sha256(tag: "file", Data(canonical.utf8)),
            title: title,
            detail: firstPath,
            searchText: paths.joined(separator: "\n"),
            byteSize: paths.reduce(0) { $0 + fileSize($1) },
            representations: [],
            offersPlainText: false,
            files: files,
            blob: nil,
            offersTIFF: false
        ))
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
        guard let text = plain, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .skip(.empty)
        }

        return .capture(Capture(
            kind: .text,
            hash: ContentHash.sha256(tag: "text", Data(text.utf8)),
            title: Self.firstLine(of: text),
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

    static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return String(line.prefix(200))
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

    /// The item's other payloads, including the HTML and source URL that a browser adds next to an
    /// image, follow in pasteboard order. If a payload would take the total past the size cap, it
    /// does not follow. The main payload remains either way.
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

    static func size(ofFileAt path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

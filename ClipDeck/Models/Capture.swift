import AppKit

struct PasteboardRepresentation: Equatable, Sendable {
    let type: String
    let data: Data
}

struct FileReference: Equatable, Sendable {
    let path: String
    let bookmark: Data?

    var name: String { (path as NSString).lastPathComponent }
}

/// The classified pasteboard is ready to be stored.
struct Capture: Equatable, Sendable {
    let kind: ClipKind
    let hash: String
    let title: String
    let detail: String?
    /// This content is indexed for search. For text items, this is the plain text itself.
    let searchText: String
    let byteSize: Int64
    /// The operation writes the item's other payloads alongside the main payload. For text items,
    /// it does not write back plain text. It rebuilds plain text from `searchText` when
    /// `offersPlainText` is set.
    let representations: [PasteboardRepresentation]
    /// The pasteboard offered plain text itself. This is false when the text was derived from RTF
    /// or HTML, so the derived text is not written back as if it were original.
    let offersPlainText: Bool
    let files: [FileReference]
    /// A content-addressed file stores image bytes or other binary data.
    let blob: PasteboardRepresentation?
    /// The pasteboard offered TIFF. The copy operation rebuilds TIFF from the blob instead of
    /// storing it.
    let offersTIFF: Bool
}

/// This provides a read-only view of a pasteboard. The view reads data on demand, so classification
/// can stop before reading a payload that classification will refuse.
struct PasteboardSnapshot {
    struct Item {
        let types: [String]
        let data: (String) -> Data?
    }

    let items: [Item]

    var allTypes: Set<String> { Set(items.flatMap(\.types)) }

    static func read(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(types: item.types.map(\.rawValue)) { item.data(forType: NSPasteboard.PasteboardType($0)) }
        }
        return PasteboardSnapshot(items: items)
    }
}

enum PasteboardTypes {
    static let concealed = "org.nspasteboard.ConcealedType"
    static let transient = "org.nspasteboard.TransientType"
    static let plainText = "public.utf8-plain-text"
    static let rtf = "public.rtf"
    static let html = "public.html"
    static let fileURL = "public.file-url"
    static let png = "public.png"
    static let tiff = "public.tiff"
    /// Image types remain unchanged if no PNG is provided.
    static let otherImages = ["public.jpeg", "public.heic", "com.compuserve.gif"]
}

import Foundation

enum ClipKind: Int, CaseIterable, Identifiable, Sendable {
    case text = 0
    /// This includes images and any other binary payload that has no associated file.
    case image = 1
    case file = 2

    var id: Self { self }

    var label: String {
        switch self {
        case .text: return "Text"
        case .image: return "Images"
        case .file: return "Files"
        }
    }

    var systemImage: String {
        switch self {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        }
    }
}

/// The list shows one history row. That row never carries the full payload.
struct ClipItem: Identifiable, Equatable, Sendable {
    let id: Int64
    let hash: String
    let kind: ClipKind
    let createdAt: Date
    let lastUsed: Date
    let title: String
    /// The value is the first file's path if files are present. Otherwise, it is nil.
    let detail: String?
    /// The start of the searchable text contains enough content for one row.
    let preview: String
    let byteSize: Int64
    let blobType: String?
    let fileCount: Int
    let isMissing: Bool

    var fileURL: URL? {
        guard kind == .file, let detail else { return nil }
        return URL(fileURLWithPath: detail)
    }
}

/// The list resumes at the last row already shown.
struct PageCursor: Equatable, Sendable {
    let lastUsed: Date
    let id: Int64

    init(after item: ClipItem) {
        lastUsed = item.lastUsed
        id = item.id
    }
}

/// This has everything needed to put an item back on the pasteboard.
struct ClipPayload: Sendable {
    let kind: ClipKind
    let plainText: String?
    let representations: [PasteboardRepresentation]
    let files: [FileReference]
    /// We read the blob's type, bytes, and the rest of the payload off the main thread. We also
    /// rebuild any TIFF off the main thread when we copy an image that includes one.
    let blob: PasteboardRepresentation?
}

import SwiftUI
import UniformTypeIdentifiers

/// ClipDeck loads an item's saved thumbnail off the main thread and hands it to `content`. Text has
/// no thumbnail. A new `refreshToken` retries loading a thumbnail that was still being generated.
struct ThumbnailReader<Content: View>: View {
    let item: ClipItem
    let location: StoreLocation
    let refreshToken: Int
    /// This is the longest side the caller draws, measured in pixels.
    var maxPixelSize = Constants.Thumbnail.maxPixelSize
    @ViewBuilder let content: (NSImage?) -> Content

    @State private var loaded: Loaded?

    private struct Loaded {
        let hash: String
        let image: NSImage
    }

    private struct Request: Hashable {
        let hash: String
        let refreshToken: Int
    }

    var body: some View {
        content(image)
            .task(id: Request(hash: item.hash, refreshToken: refreshToken)) {
                guard item.kind != .text, loaded?.hash != item.hash else { return }
                let url = location.thumbnailURL(for: item.hash)
                if let image = await ThumbnailCache.shared.image(for: item.hash, at: url, maxPixelSize: maxPixelSize) {
                    loaded = Loaded(hash: item.hash, image: image)
                }
            }
    }

    /// A row that scrolls back into view reads the cache here. Thus, the row shows its thumbnail at
    /// once and never shows the placeholder first.
    private var image: NSImage? {
        guard item.kind != .text else { return nil }
        if let loaded, loaded.hash == item.hash { return loaded.image }
        return ThumbnailCache.shared.cachedImage(for: item.hash, maxPixelSize: maxPixelSize)
            ?? ThumbnailCache.shared.cachedImage(for: item.hash)
    }
}

/// The square thumbnail appears at the start of a row.
struct ThumbnailView: View {
    let item: ClipItem
    let location: StoreLocation
    let side: CGFloat
    let refreshToken: Int

    var body: some View {
        ThumbnailReader(
            item: item, location: location, refreshToken: refreshToken,
            maxPixelSize: Constants.Panel.rowThumbnailPixelSize
        ) { image in
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // A file type icon has its own shape, so only a symbol sits in a well.
                    if FileTypeIcon.icon(for: item) == nil {
                        RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                            .fill(Palette.surface1)
                    }
                    ItemPlaceholder(item: item, iconSide: side, symbolSize: Glyph.inline)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
            .opacity(item.isMissing ? Constants.Panel.missingItemOpacity : 1)
        }
        .accessibilityHidden(true)
    }
}

/// Before an item has a thumbnail, or when it cannot have one, it shows the file type's icon for a
/// file and the kind's symbol for everything else.
struct ItemPlaceholder: View {
    let item: ClipItem
    let iconSide: CGFloat
    let symbolSize: CGFloat

    var body: some View {
        if let icon = FileTypeIcon.icon(for: item) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSide, height: iconSide)
        } else {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: symbolSize, weight: .light))
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

/// File type icons use the path extension. Each extension is resolved once, and the icon comes from
/// the type. Nothing here reads the disk.
@MainActor
enum FileTypeIcon {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: ClipItem) -> NSImage? {
        guard item.kind == .file, let path = item.detail else { return nil }
        let pathExtension = (path as NSString).pathExtension.lowercased()
        if let cached = cache[pathExtension] { return cached }
        guard let type = UTType(filenameExtension: pathExtension) else { return nil }
        let icon = NSWorkspace.shared.icon(for: type)
        cache[pathExtension] = icon
        return icon
    }
}

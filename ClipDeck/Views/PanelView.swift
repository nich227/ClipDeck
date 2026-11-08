import SwiftUI

struct PanelView: View {
    @ObservedObject var viewModel: HistoryViewModel
    let onCopy: () -> Void

    @FocusState private var searchFocused: Bool
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Hairline(axis: .horizontal)
            HStack(spacing: 0) {
                listArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Hairline(axis: .vertical)
                PreviewPane(
                    item: viewModel.selectedItem,
                    store: viewModel.store,
                    isActive: viewModel.isVisible,
                    refreshToken: viewModel.refreshToken
                )
                    .frame(width: Constants.Panel.previewWidth)
            }
            Hairline(axis: .horizontal)
            footer
        }
        .frame(width: Constants.Panel.width, height: Constants.Panel.height)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : -Space.xs)
        .onChange(of: viewModel.isVisible) { _, visible in
            visible ? reveal() : (appeared = false)
        }
        .onAppear(perform: reveal)
    }

    private func reveal() {
        withAnimation(Anim.allowed(Anim.standard, reduceMotion: reduceMotion)) { appeared = true }
        // The field can take focus only on the next run loop turn after the panel becomes key.
        DispatchQueue.main.async { searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Palette.textTertiary)
            TextField("Search", text: $viewModel.query)
                .textFieldStyle(.plain)
                .deckFont(.search)
                .foregroundStyle(Palette.textPrimary)
                .focused($searchFocused)
                .accessibilityLabel("Search your clipboard history")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    @ViewBuilder
    private var listArea: some View {
        if viewModel.items.isEmpty {
            EmptyStateView(isSearching: viewModel.isSearching, isActive: viewModel.isVisible)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Space.xxs) {
                        ForEach(viewModel.items) { item in
                            ClipRow(
                                item: item,
                                isSelected: item.id == viewModel.selectedID,
                                thumbnailURL: viewModel.store.location.thumbnailURL(for: item.hash),
                                refreshToken: viewModel.refreshToken
                            )
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                viewModel.select(item)
                                onCopy()
                            }
                            .onTapGesture { viewModel.select(item) }
                            .onAppear { viewModel.loadMoreIfNeeded(after: item) }
                        }
                    }
                    .padding(Space.xs)
                }
                .onChange(of: viewModel.selectedID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Space.md) {
            KeyHint(key: "\u{21A9}", label: "Copy")
            KeyHint(key: "\u{2191}\u{2193}", label: "Move")
            KeyHint(key: "esc", label: "Close")
            Spacer()
            Text("Press Return to copy an item, then paste it in any app.")
                .deckFont(.caption)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.xs)
    }
}

struct Hairline: View {
    let axis: Axis

    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

private struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: Space.xxs) {
            Text(key)
                .deckFont(.mono)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, Space.xxs)
                .background(RoundedRectangle(cornerRadius: Radius.xs).fill(Palette.surface1))
            Text(label)
                .deckFont(.caption)
                .foregroundStyle(Palette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ClipRow: View {
    let item: ClipItem
    let isSelected: Bool
    let thumbnailURL: URL
    let refreshToken: Int

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Space.sm) {
            ThumbnailView(item: item, url: thumbnailURL, side: 32, fill: true, refreshToken: refreshToken)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(item.title)
                    .deckFont(.body)
                    .foregroundStyle(item.isMissing ? Palette.textTertiary : Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: Space.xxs) {
                    if item.isMissing {
                        Text("Not Found").foregroundStyle(Palette.caution)
                    }
                    Text(ItemFormatting.subtitle(for: item))
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .deckFont(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(isSelected ? Palette.surface2 : (isHovered ? Palette.surface1 : Color.clear))
        )
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(Palette.accent)
                    .frame(width: 2, height: 16)
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ThumbnailView: View {
    let item: ClipItem
    let url: URL
    let side: CGFloat
    let fill: Bool
    let refreshToken: Int

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                .fill(Palette.surface1)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Image(systemName: item.kind.systemImage)
                    .font(.system(size: side * 0.4, weight: .light))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
        .opacity(item.isMissing ? 0.4 : 1)
        .task(id: "\(item.hash)#\(refreshToken)") {
            guard item.kind != .text else {
                image = nil
                return
            }
            if let cached = ThumbnailCache.shared.cachedImage(for: item.hash) {
                image = cached
            } else {
                image = await ThumbnailCache.shared.image(for: item.hash, at: url)
            }
        }
    }
}

struct EmptyStateView: View {
    let isSearching: Bool
    /// The animation runs only while the panel is on screen.
    let isActive: Bool

    var body: some View {
        VStack(spacing: Space.sm) {
            glyph
            Text(isSearching ? "No Results" : "No Items")
                .deckFont(.label)
                .foregroundStyle(Palette.textSecondary)
            Text(isSearching ? "Try a different search." : "Items you copy will appear here.")
                .deckFont(.caption)
                .foregroundStyle(Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var glyph: some View {
        if isSearching {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.accent)
                .frame(width: 72, height: 72)
        } else {
            DeckAnimation(name: Constants.Animations.paperclip, loops: true, isActive: isActive)
                .frame(width: 72, height: 72)
        }
    }
}

enum ItemFormatting {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        relative.localizedString(for: date, relativeTo: now)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func subtitle(for item: ClipItem) -> String {
        let time = relativeTime(item.lastUsed)
        switch item.kind {
        case .text:
            return "Text \u{00B7} \(time)"
        case .image:
            return "\(typeName(item.blobType)) \u{00B7} \(size(item.byteSize)) \u{00B7} \(time)"
        case .file:
            let path = (item.detail as NSString?)?.abbreviatingWithTildeInPath ?? ""
            return "\(path) \u{00B7} \(time)"
        }
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

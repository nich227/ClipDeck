import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// The right side of the panel shows a larger view of the selected item.
struct PreviewPane: View, Equatable {
    let item: ClipItem?
    let store: ClipStore
    let isActive: Bool
    let refreshToken: Int

    /// The full text belongs to one item, so a new selection never shows the last item's text.
    @State private var fullText: (id: Int64, text: String)?
    /// The full text loads and the video plays only after the item stays selected through the
    /// settle delay.
    @State private var settledID: Int64?

    nonisolated static func == (lhs: PreviewPane, rhs: PreviewPane) -> Bool {
        lhs.isActive == rhs.isActive && lhs.refreshToken == rhs.refreshToken && lhs.item == rhs.item
    }

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: Space.sm) {
                content(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Hairline(axis: .horizontal)
                metadata(for: item)
            }
            .padding(Space.md)
            .task(id: item.id) { await settle(on: item) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Preview")
        } else {
            Color.clear
        }
    }

    private func settle(on item: ClipItem) async {
        try? await Task.sleep(for: Constants.Panel.previewSettle)
        guard !Task.isCancelled else { return }
        settledID = item.id
        guard item.kind == .text, let text = try? await store.textPreview(for: item.id), !Task.isCancelled else { return }
        fullText = (item.id, text)
    }

    @ViewBuilder
    private func content(for item: ClipItem) -> some View {
        switch item.kind {
        case .text:
            ScrollView {
                Text(fullText?.id == item.id ? fullText?.text ?? item.preview : item.preview)
                    .deckFont(.mono)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .image:
            VStack(alignment: .leading, spacing: Space.xs) {
                PreviewArtwork(item: item, location: store.location, refreshToken: refreshToken)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if item.isMissing {
                    notice("This image is no longer available.")
                }
            }
        case .file:
            VStack(alignment: .leading, spacing: Space.xs) {
                Group {
                    if let url = item.fileURL, isActive, !item.isMissing, settledID == item.id, Self.isVideo(url) {
                        VideoPreview(url: url)
                            .id(item.id)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                            .accessibilityLabel("Video preview")
                    } else {
                        PreviewArtwork(item: item, location: store.location, refreshToken: refreshToken)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: Constants.Panel.previewArtworkHeight, alignment: .topLeading)
                Text(item.title)
                    .deckFont(.label)
                    .foregroundStyle(item.isMissing ? Palette.textSecondary : Palette.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let path = item.detail {
                    Text(ItemFormatting.abbreviatedPath(path))
                        .deckFont(.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if item.isMissing {
                    notice("This file can't be found. Press Return to copy its path.")
                }
            }
        }
    }

    /// The caution wraps instead of truncating because it is the one line that explains why the
    /// item looks different.
    private func notice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .deckFont(.caption)
            .foregroundStyle(Palette.caution)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func metadata(for item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(ItemFormatting.metadata(for: item))
            Text("Copied \(ItemFormatting.relativeTime(item.lastUsed))")
        }
        .deckFont(.caption)
        .foregroundStyle(Palette.textSecondary)
        .lineLimit(1)
    }

    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }
}

/// The selected image or file appears at the size the pane allows. The picture keeps its shape and
/// sits at the top. An item with no picture shows its file type icon or its kind in a well.
private struct PreviewArtwork: View {
    let item: ClipItem
    let location: StoreLocation
    let refreshToken: Int

    var body: some View {
        ThumbnailReader(item: item, location: location, refreshToken: refreshToken) { image in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            } else {
                ItemPlaceholder(item: item, iconSide: Glyph.illustration, symbolSize: Glyph.state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(maxHeight: Constants.Panel.previewArtworkHeight)
                    .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Palette.surface1))
            }
        }
        .opacity(item.isMissing ? Constants.Panel.missingItemOpacity : 1)
        .accessibilityHidden(true)
    }
}

/// The inline playback is muted. It plays once and stops at the end.
struct VideoPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        view.player = player
        player.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

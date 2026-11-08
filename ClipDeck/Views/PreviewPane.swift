import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// The right side of the panel shows a larger view of the selected item.
struct PreviewPane: View {
    let item: ClipItem?
    let store: ClipStore
    let isActive: Bool
    let refreshToken: Int

    @State private var text = ""

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: Space.sm) {
                content(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Hairline(axis: .horizontal)
                metadata(for: item)
            }
            .padding(Space.md)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func content(for item: ClipItem) -> some View {
        switch item.kind {
        case .text:
            ScrollView {
                Text(text)
                    .deckFont(.mono)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: item.id) {
                text = item.preview
                if let full = try? await store.textPreview(for: item.id) { text = full }
            }
        case .image:
            VStack(alignment: .leading, spacing: Space.xs) {
                largeThumbnail(for: item)
                if item.isMissing {
                    Label("This image is no longer available.", systemImage: "exclamationmark.triangle")
                        .deckFont(.caption)
                        .foregroundStyle(Palette.caution)
                }
            }
        case .file:
            VStack(alignment: .leading, spacing: Space.xs) {
                if let url = item.fileURL, isActive, !item.isMissing, Self.isVideo(url) {
                    VideoPreview(url: url)
                        .id(item.id)
                        .frame(maxWidth: .infinity)
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                } else {
                    largeThumbnail(for: item)
                }
                Text(item.title)
                    .deckFont(.label)
                    .foregroundStyle(item.isMissing ? Palette.textTertiary : Palette.textPrimary)
                    .lineLimit(2)
                if let path = item.detail {
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .deckFont(.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
                if item.isMissing {
                    Label("This file can't be found. Press Return to copy its path.", systemImage: "exclamationmark.triangle")
                        .deckFont(.caption)
                        .foregroundStyle(Palette.caution)
                }
            }
        }
    }

    private func largeThumbnail(for item: ClipItem) -> some View {
        ThumbnailView(
            item: item,
            url: store.location.thumbnailURL(for: item.hash),
            side: Constants.Panel.previewWidth - 2 * Space.md,
            fill: false,
            refreshToken: refreshToken
        )
    }

    private func metadata(for item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(metadataLine(for: item))
            Text("Copied \(ItemFormatting.relativeTime(item.lastUsed))")
        }
        .deckFont(.caption)
        .foregroundStyle(Palette.textTertiary)
    }

    private func metadataLine(for item: ClipItem) -> String {
        switch item.kind {
        case .text: return "Text \u{00B7} \(ItemFormatting.size(item.byteSize))"
        case .image: return "\(ItemFormatting.typeName(item.blobType)) \u{00B7} \(ItemFormatting.size(item.byteSize))"
        case .file:
            let count = item.fileCount == 1 ? "1 file" : "\(item.fileCount) files"
            return "\(count) \u{00B7} \(ItemFormatting.size(item.byteSize))"
        }
    }

    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
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

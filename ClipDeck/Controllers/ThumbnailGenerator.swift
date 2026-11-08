import AppKit
import QuickLookThumbnailing

/// The code creates one PNG thumbnail per file or image item off the main thread and saves it
/// through the store. The list reads only these cached files.
final class ThumbnailGenerator: Sendable {
    private let store: ClipStore

    init(store: ClipStore) {
        self.store = store
    }

    /// Returns true when a new thumbnail was saved.
    @discardableResult
    func generate(for capture: Capture) async -> Bool {
        guard capture.kind != .text else { return false }
        let destination = store.location.thumbnailURL(for: capture.hash)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return false }

        let image: CGImage?
        switch capture.kind {
        case .file:
            guard let path = capture.files.first?.path else { return false }
            image = await quickLookThumbnail(for: URL(fileURLWithPath: path))
        case .image:
            image = ImageProcessing.thumbnail(
                from: store.location.blobURL(for: capture.hash),
                maxPixelSize: Constants.Thumbnail.maxPixelSize
            )
        case .text:
            return false
        }

        guard let image, let png = ImageProcessing.pngData(from: image) else { return false }
        do {
            return try await store.saveThumbnail(png, for: capture.hash)
        } catch {
            Log.thumbnails.error("Could not save a thumbnail: \(error.localizedDescription)")
            return false
        }
    }

    private func quickLookThumbnail(for url: URL) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: Constants.Thumbnail.pointSize,
            scale: Constants.Thumbnail.scale,
            representationTypes: .all
        )
        do {
            return try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
        } catch {
            Log.thumbnails.debug("No thumbnail for a file: \(error.localizedDescription)")
            return nil
        }
    }
}

/// This cache holds decoded thumbnails for the rows on screen. Reads happen off the main thread.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    func cachedImage(for hash: String) -> NSImage? {
        cache.object(forKey: hash as NSString)
    }

    func image(for hash: String, at url: URL) async -> NSImage? {
        if let cached = cachedImage(for: hash) { return cached }
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        guard let data, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: hash as NSString)
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

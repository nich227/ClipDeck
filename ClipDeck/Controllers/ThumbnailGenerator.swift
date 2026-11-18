import AppKit
import QuickLookThumbnailing
import os

extension Notification.Name {
    /// This appears on the main thread after a thumbnail is saved. The object is the item's hash.
    static let clipThumbnailDidChange = Notification.Name("com.kevster.clipdeck.thumbnailDidChange")
}

/// The code creates one PNG thumbnail per file or image item off the main thread and saves it
/// through the store. The list reads only these cached files.
final class ThumbnailGenerator: Sendable {
    private let store: ClipStore
    /// It tracks the hashes of thumbnails in progress, so a repeat copy does not render the same
    /// thumbnail again.
    private let inFlight = OSAllocatedUnfairLock(initialState: Set<String>())

    init(store: ClipStore) {
        self.store = store
    }

    /// Returns true when a new thumbnail was saved. A second request for the same hash returns
    /// false at once if the first request is still in progress. The first request reports the
    /// result.
    @discardableResult
    func generate(for capture: Capture) async -> Bool {
        guard capture.kind != .text else { return false }
        let hash = capture.hash
        guard inFlight.withLock({ $0.insert(hash).inserted }) else { return false }
        defer { inFlight.withLock { _ = $0.remove(hash) } }
        let destination = store.location.thumbnailURL(for: hash)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return false }

        let image: CGImage?
        switch capture.kind {
        case .file:
            guard let path = capture.files.first?.path else { return false }
            image = await quickLookThumbnail(for: URL(fileURLWithPath: path))
        case .image:
            image = ImageProcessing.thumbnail(
                from: store.location.blobURL(for: hash),
                maxPixelSize: Constants.Thumbnail.maxPixelSize
            )
        case .text:
            return false
        }

        guard let image, let png = ImageProcessing.pngData(from: image) else { return false }
        do {
            return try await store.saveThumbnail(png, for: hash)
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

/// This cache holds decoded thumbnails for the rows on screen. It reads and decodes each file off
/// the main thread. The cached image is a plain bitmap, so drawing it never decodes. Requests for a
/// thumbnail that is already loading share that load. The cache holds at most
/// `Constants.Thumbnail.cacheCostLimit` bytes of bitmaps. The system may empty it at any time.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private var loads: [String: Task<NSImage?, Never>] = [:]
    /// This changes when the cache is emptied, so a load that began before the cache was emptied
    /// does not put its image back.
    private var epoch = 0

    init(costLimit: Int = Constants.Thumbnail.cacheCostLimit) {
        cache.totalCostLimit = costLimit
    }

    /// `maxPixelSize` is the longest side the caller draws, in pixels. A smaller image costs less
    /// to keep and to draw. Each size is cached on its own.
    func cachedImage(for hash: String, maxPixelSize: Int = Constants.Thumbnail.maxPixelSize) -> NSImage? {
        cache.object(forKey: Self.key(hash, maxPixelSize) as NSString)
    }

    func image(for hash: String, at url: URL, maxPixelSize: Int = Constants.Thumbnail.maxPixelSize) async -> NSImage? {
        let key = Self.key(hash, maxPixelSize)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let running = loads[key] { return await running.value }
        let epoch = self.epoch
        let load = Task { [weak self] () -> NSImage? in
            let bitmap = await Task.detached(priority: .userInitiated) {
                ImageProcessing.thumbnail(from: url, maxPixelSize: maxPixelSize)
            }.value
            guard let self else { return nil }
            self.loads[key] = nil
            guard let bitmap else { return nil }
            let image = NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
            if epoch == self.epoch {
                self.cache.setObject(image, forKey: key as NSString, cost: bitmap.bytesPerRow * bitmap.height)
            }
            return image
        }
        loads[key] = load
        return await load.value
    }

    func removeAll() {
        epoch += 1
        cache.removeAllObjects()
    }

    private static func key(_ hash: String, _ maxPixelSize: Int) -> String {
        maxPixelSize == Constants.Thumbnail.maxPixelSize ? hash : "\(hash)@\(maxPixelSize)"
    }
}

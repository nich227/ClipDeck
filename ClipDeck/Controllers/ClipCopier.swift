import AppKit

/// This path restores a stored item to the pasteboard with its original types and moves it to the
/// top of history. Both the panel and menu bar menu use this path to copy the item.
@MainActor
final class ClipCopier {
    private let store: ClipStore
    private let monitor: PasteboardMonitor
    /// After a successful copy, this is called with the item returned to the pasteboard.
    var onCopied: ((ClipItem) -> Void)?

    init(store: ClipStore, monitor: PasteboardMonitor) {
        self.store = store
        self.monitor = monitor
    }

    /// Returns false when the item cannot be read back or written. The pasteboard remains unchanged
    /// in either case.
    @discardableResult
    func copy(_ item: ClipItem) async -> Bool {
        guard let payload = try? await store.payload(for: item.id) else {
            Log.panel.error("Item \(item.id) could not be read back; nothing was copied")
            NSSound.beep()
            return false
        }
        guard monitor.writeOwn({ PasteboardWriter.write(payload, to: $0) }) else { return false }
        try? await store.touch(id: item.id)
        NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
        onCopied?(item)
        return true
    }
}

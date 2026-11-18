import AppKit

/// This path restores a stored item to the pasteboard with its original types and moves it to the
/// top of history. Both the panel and menu bar menu use this path to copy the item.
@MainActor
final class ClipCopier {
    private let store: ClipStore
    private let monitor: PasteboardMonitor
    /// After a successful copy, this receives the item returned to the pasteboard.
    var onCopied: ((ClipItem) -> Void)?
    /// The copier calls this when it cannot read an item back from the store or write it to the
    /// pasteboard. It does so for a copy from the panel and for a copy from the menu.
    var onFailed: () -> Void = ClipCopier.signalFailure

    init(store: ClipStore, monitor: PasteboardMonitor) {
        self.store = store
        self.monitor = monitor
    }

    /// Returns false when the item cannot be read back or written. Nothing is copied in either
    /// case.
    @discardableResult
    func copy(_ item: ClipItem) async -> Bool {
        guard let payload = try? await store.payload(for: item.id) else {
            Log.panel.error("Item \(item.id) could not be read back; nothing was copied")
            fail()
            return false
        }
        // File bookmarks need disk access. Text and images are ready as they are.
        let prepared = payload.kind == .file
            ? await Task.detached(priority: .userInitiated) { PasteboardWriter.prepare(payload) }.value
            : PasteboardWriter.prepare(payload)
        guard monitor.writeOwn({ PasteboardWriter.write(prepared, to: $0) }) else {
            Log.panel.error("Item \(item.id) could not be written; nothing was copied")
            fail()
            return false
        }
        // The confirmation does not wait for the store.
        onCopied?(item)
        try? await store.touch(id: item.id)
        NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
        return true
    }

    /// The row that failed is out of date wherever it appears, so the lists read the history again.
    private func fail() {
        onFailed()
        NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
    }

    static let failureAnnouncement = "This item is no longer available. Nothing was copied."

    /// A failed copy shows no confirmation. An alert sounds, and VoiceOver announces that nothing
    /// was copied when VoiceOver is on.
    static func signalFailure() {
        NSSound.beep()
        CopyHUDController.announce(failureAnnouncement)
    }
}

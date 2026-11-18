import AppKit
import SwiftUI

/// This owns the Clear History window, which the menu bar and Settings share.
@MainActor
final class ClearHistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = ClearHistoryWindowController()

    /// Set it once at launch.
    var store: ClipStore?
    private var window: NSWindow?

    func show() {
        guard let store else { return }
        let window = self.window ?? makeWindow(store: store)
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        DockPresence.shared.windowDidOpen(window)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let window { DockPresence.shared.windowDidClose(window) }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !window.isVisible else { return }
            window.contentViewController = nil
            self.window = nil
        }
    }

    private func makeWindow(store: ClipStore) -> NSWindow {
        let view = ClearHistoryView(store: store) { [weak self] in self?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        // The view has the heading, so the title bar does not repeat it. The title still names the
        // window in the Window menu and for VoiceOver.
        window.title = "Clear History"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

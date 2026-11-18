import AppKit

/// ClipDeck appears in the Dock while one of its windows is open and leaves when the last one
/// closes. A menu bar app has no Dock icon, but its windows are hard to find again without one.
/// Thus, the Settings, Clear History, and file access windows request a Dock icon.
@MainActor
final class DockPresence {
    static let shared = DockPresence()

    private var holders: Set<ObjectIdentifier> = []

    func windowDidOpen(_ window: NSWindow) {
        holders.insert(ObjectIdentifier(window))
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        // Activate it again so that the policy change takes effect.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidClose(_ window: NSWindow) {
        holders.remove(ObjectIdentifier(window))
        guard holders.isEmpty, NSApp.activationPolicy() == .regular else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

import AppKit

/// Puts ClipDeck in the Dock while one of its windows is open and takes it back out when the
/// last one closes. A menu bar app has no Dock icon, but a window with no Dock icon behind it
/// is hard to find again, so the Settings and Clear History windows ask for one.
@MainActor
final class DockPresence {
    static let shared = DockPresence()

    private var holders: Set<ObjectIdentifier> = []

    func windowDidOpen(_ window: NSWindow) {
        holders.insert(ObjectIdentifier(window))
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        // The policy change takes effect on the next activation, so activate again.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidClose(_ window: NSWindow) {
        holders.remove(ObjectIdentifier(window))
        guard holders.isEmpty, NSApp.activationPolicy() == .regular else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

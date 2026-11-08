import AppKit
import Sparkle
import SwiftUI

/// It owns the Settings window, a toolbar-style tab view with one SwiftUI pane per tab. The same
/// window opens from the menu bar, the History pane, or when the app reopens. The window returns to
/// the last viewed pane.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// Set it once at launch.
    var store: ClipStore?
    var updater: SPUStandardUpdaterController?

    private var window: NSWindow?
    private var tabs: SettingsTabViewController?

    func show(_ section: SettingsSection? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        if let section { tabs?.select(section) }
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        DockPresence.shared.windowDidOpen(window)
    }

    private func makeWindow() -> NSWindow {
        let tabs = SettingsTabViewController(store: store, updater: updater)
        self.tabs = tabs
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    /// A closed window keeps its SwiftUI panes alive, including the recorder monitors. Thus, the
    /// window tears down and rebuilds the panes the next time it appears.
    func windowWillClose(_ notification: Notification) {
        if let window { DockPresence.shared.windowDidClose(window) }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !window.isVisible else { return }
            window.contentViewController = nil
            self.window = nil
            self.tabs = nil
        }
    }
}

@MainActor
private final class SettingsTabViewController: NSTabViewController {
    private static let lastPaneKey = "settingsLastPane"

    init(store: ClipStore?, updater: SPUStandardUpdaterController?) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.crossfade, .allowUserInteraction]
        for section in SettingsSection.allCases {
            let pane = NSHostingController(rootView: SettingsPane(section: section, store: store, updater: updater))
            pane.sizingOptions = [.preferredContentSize]
            pane.title = section.title
            let item = NSTabViewItem(viewController: pane)
            item.label = section.title
            item.image = NSImage(systemSymbolName: section.systemImage, accessibilityDescription: section.title)
            item.identifier = section.rawValue
            addTabViewItem(item)
        }
        let saved = UserDefaults.standard.string(forKey: Self.lastPaneKey).flatMap(SettingsSection.init(rawValue:))
        select(saved ?? .general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func select(_ section: SettingsSection) {
        guard let index = SettingsSection.allCases.firstIndex(of: section) else { return }
        selectedTabViewItemIndex = index
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String {
            UserDefaults.standard.set(id, forKey: Self.lastPaneKey)
        }
    }
}

private struct SettingsPane: View {
    let section: SettingsSection
    let store: ClipStore?
    let updater: SPUStandardUpdaterController?

    var body: some View {
        switch section {
        case .general: GeneralSettingsPane()
        case .history: HistorySettingsPane(store: store)
        case .about: AboutSettingsPane(updater: updater)
        }
    }
}

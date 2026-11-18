import AppKit
import Carbon
import Sparkle
import UniformTypeIdentifiers

/// The menu bar item shows the most recent items for one-click copying, then the app's commands.
/// When the history changes, the app refreshes the rows with one indexed read of ten rows. Changes
/// that arrive while a read is in flight share one more read. Thumbnails load only while the menu
/// is open.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    struct Actions {
        let openPanel: () -> Void
        let copy: (ClipItem) -> Void
        let clearHistory: () -> Void
        let openSettings: () -> Void
    }

    private let store: ClipStore
    private let fetchRecent: @MainActor () async throws -> [ClipItem]
    private let actions: Actions
    /// The menu's Check for Updates row targets this directly, so Sparkle enables and disables it
    /// through menu validation.
    private let updater: SPUStandardUpdaterController?
    /// This is nil when tests create the controller without a status bar.
    private let statusItem: NSStatusItem?
    let menu = NSMenu()
    private(set) var recent: [ClipItem] = []
    private var observers: [ObserverToken] = []
    private var iconLoads: Task<Void, Never>?
    private var needsRefresh = false
    private var refreshRunner: Task<Void, Never>?
    /// The menu reuses row icons drawn from a thumbnail or file type, so reopening it does not
    /// build them again. `refreshRecent` drops thumbnail icons for rows that left the menu.
    private var thumbnailIcons: [String: NSImage] = [:]
    private var typeIcons: [String: NSImage] = [:]
    private var symbolIcons: [String: NSImage] = [:]

    init(
        store: ClipStore,
        actions: Actions,
        updater: SPUStandardUpdaterController?,
        statusBar: NSStatusBar? = .system,
        fetchRecent: (@MainActor () async throws -> [ClipItem])? = nil
    ) {
        self.store = store
        self.fetchRecent = fetchRecent ?? { try await store.page(limit: Constants.Menu.recentCount) }
        self.actions = actions
        self.updater = updater
        statusItem = statusBar?.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem?.button {
            let icon = NSImage(named: "MenuBarIcon")
            icon?.isTemplate = true
            button.image = icon
            button.toolTip = Constants.appName
        }
        menu.delegate = self
        statusItem?.menu = menu
        applyVisibility()

        let center = NotificationCenter.default
        observers = [
            ObserverToken(center.addObserver(forName: .clipHistoryDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRecent() }
            }),
            ObserverToken(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyVisibility() }
            }),
        ]
        refreshRecent()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    func menuDidClose(_ menu: NSMenu) {
        iconLoads?.cancel()
        iconLoads = nil
    }

    // MARK: - Building

    private func rebuild() {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: "Recent"))
        if recent.isEmpty {
            menu.addItem(NSMenuItem(title: "No Items", action: nil, keyEquivalent: ""))
        }
        for (position, item) in recent.enumerated() {
            menu.addItem(row(for: item, key: Constants.Menu.rowKeys[position]))
        }
        menu.addItem(.separator())
        let open = command("Open ClipDeck", #selector(openPanel))
        Self.applyShortcut(HotkeyConfig.load(from: .standard), to: open)
        menu.addItem(open)
        menu.addItem(command("Clear History\u{2026}", #selector(clearHistory)))
        menu.addItem(command("Settings\u{2026}", #selector(openSettings), key: ","))
        if let updater {
            let check = NSMenuItem(
                title: "Check for Updates\u{2026}", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: ""
            )
            check.target = updater
            menu.addItem(check)
        }
        menu.addItem(.separator())
        menu.addItem(command("Quit ClipDeck", #selector(quit), key: "q"))
        loadThumbnails()
    }

    /// A recent row shows its key equivalent, Command plus a digit, in the menu's own gray on the
    /// right. It works while the menu is open.
    private func row(for item: ClipItem, key: String) -> NSMenuItem {
        let title = MenuFormatting.title(for: item)
        let row = NSMenuItem(title: title, action: #selector(copyRow(_:)), keyEquivalent: key)
        row.keyEquivalentModifierMask = .command
        row.target = self
        row.representedObject = item.id
        row.image = placeholderIcon(for: item)
        row.toolTip = MenuFormatting.tooltip(for: item, title: title)
        return row
    }

    private func command(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// Shows the global shortcut on a menu item like every other menu shortcut. Carbon registers
    /// the shortcut itself, so the menu item only displays it.
    static func applyShortcut(_ config: HotkeyConfig, to item: NSMenuItem) {
        guard let key = Self.menuKeyEquivalent(for: config) else { return }
        item.keyEquivalent = key
        var mask: NSEvent.ModifierFlags = []
        if config.modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        if config.modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if config.modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if config.modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        item.keyEquivalentModifierMask = mask
    }

    /// This is the character for a menu key equivalent, or nil if the menu cannot show the key.
    static func menuKeyEquivalent(for config: HotkeyConfig) -> String? {
        func function(_ key: Int) -> String { UnicodeScalar(key).map { String(Character($0)) } ?? "" }
        let special: [Int: String] = [
            kVK_Return: "\r", kVK_Tab: "\t", kVK_Space: " ", kVK_Delete: "\u{8}", kVK_Escape: "\u{1B}",
            kVK_UpArrow: function(NSUpArrowFunctionKey), kVK_DownArrow: function(NSDownArrowFunctionKey),
            kVK_LeftArrow: function(NSLeftArrowFunctionKey), kVK_RightArrow: function(NSRightArrowFunctionKey),
        ]
        if let mapped = special[Int(config.keyCode)] { return mapped }
        let label = config.keyLabel
        guard label.count == 1 else { return nil }
        return label.lowercased()
    }

    /// While a row's thumbnail decodes, the row shows a cached thumbnail if one exists. Otherwise,
    /// it shows the file type's icon or the kind's glyph. None of these options accesses the disk.
    private func placeholderIcon(for item: ClipItem) -> NSImage? {
        if item.kind != .text, let icon = thumbnailIcon(for: item.hash) { return icon }
        switch item.kind {
        case .text, .image:
            return symbolIcon(item.kind.systemImage)
        case .file:
            return typeIcon(forExtension: item.fileURL?.pathExtension ?? "") ?? symbolIcon(item.kind.systemImage)
        }
    }

    private func thumbnailIcon(for hash: String) -> NSImage? {
        if let icon = thumbnailIcons[hash] { return icon }
        guard let cached = ThumbnailCache.shared.cachedImage(for: hash, maxPixelSize: Constants.Menu.iconPixelSize)
            ?? ThumbnailCache.shared.cachedImage(for: hash) else { return nil }
        let icon = MenuIcon.square(cached)
        thumbnailIcons[hash] = icon
        return icon
    }

    private func symbolIcon(_ name: String) -> NSImage? {
        if let icon = symbolIcons[name] { return icon }
        let icon = MenuIcon.symbol(name)
        symbolIcons[name] = icon
        return icon
    }

    private func typeIcon(forExtension pathExtension: String) -> NSImage? {
        if let icon = typeIcons[pathExtension] { return icon }
        guard let type = UTType(filenameExtension: pathExtension) else { return nil }
        if typeIcons.count >= Constants.Menu.typeIconLimit { typeIcons.removeAll() }
        let icon = MenuIcon.square(NSWorkspace.shared.icon(for: type))
        typeIcons[pathExtension] = icon
        return icon
    }

    /// The process decodes and replaces each missing row thumbnail one at a time while the menu is
    /// open. Closing the menu cancels it.
    private func loadThumbnails() {
        iconLoads?.cancel()
        let pending = recent.filter { $0.kind != .text && !$0.isMissing && thumbnailIcons[$0.hash] == nil }
        guard !pending.isEmpty else { return }
        iconLoads = Task { [weak self] in
            for item in pending {
                guard let self, !Task.isCancelled else { return }
                let url = store.location.thumbnailURL(for: item.hash)
                let image = await ThumbnailCache.shared.image(for: item.hash, at: url, maxPixelSize: Constants.Menu.iconPixelSize)
                guard let image, !Task.isCancelled else { continue }
                let icon = MenuIcon.square(image)
                thumbnailIcons[item.hash] = icon
                menu.items.first { $0.representedObject as? Int64 == item.id }?.image = icon
            }
        }
    }

    // MARK: - State

    /// One read runs at a time. One more read handles every change that arrives during the first
    /// read, so a burst costs two reads instead of one per change.
    private func refreshRecent() {
        needsRefresh = true
        guard refreshRunner == nil else { return }
        refreshRunner = Task { [weak self] in await self?.runRefreshes() }
    }

    private func runRefreshes() async {
        defer { refreshRunner = nil }
        while needsRefresh {
            needsRefresh = false
            guard let rows = try? await fetchRecent(), rows != recent else { continue }
            recent = rows
            let shown = Set(rows.map(\.hash))
            thumbnailIcons = thumbnailIcons.filter { shown.contains($0.key) }
        }
    }

    private func applyVisibility() {
        statusItem?.isVisible = UserDefaults.standard.object(forKey: Constants.showMenuBarIconKey) as? Bool ?? true
    }

    // MARK: - Actions

    @objc private func copyRow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64, let item = recent.first(where: { $0.id == id }) else { return }
        actions.copy(item)
    }

    @objc private func openPanel() { actions.openPanel() }
    @objc private func clearHistory() { actions.clearHistory() }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

/// Each menu row icon uses `Constants.Menu.iconSide` for its width and height.
enum MenuIcon {
    static func symbol(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: Glyph.inline, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    /// The image fills a rounded square, and any part that does not fit is cropped.
    static func square(_ source: NSImage, side: CGFloat = Constants.Menu.iconSide) -> NSImage {
        let size = NSSize(width: side, height: side)
        return NSImage(size: size, flipped: false) { rect in
            let sourceSize = source.size
            guard sourceSize.width > 0, sourceSize.height > 0 else { return false }
            NSBezierPath(roundedRect: rect, xRadius: Radius.xs, yRadius: Radius.xs).addClip()
            let scale = max(rect.width / sourceSize.width, rect.height / sourceSize.height)
            let drawn = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            let origin = NSPoint(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2)
            source.draw(in: NSRect(origin: origin, size: drawn), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}

import AppKit
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ClipStore?
    private var monitor: PasteboardMonitor?
    private var panel: PanelController?
    private var menuBar: MenuBarController?
    private var updater: SPUStandardUpdaterController?
    private let hud = CopyHUDController()
    private lazy var hotkeys = HotkeyManager { [weak self] in self?.togglePanel() }
    private var observers: [NSObjectProtocol] = []
    /// The app reopened before its store was ready, so Settings opens once the store is ready.
    private var opensSettingsOnStart = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app. They must never touch the real history.
        guard !Self.isRunningUnitTests else { return }
        DeckAnimation.preload()
        NSApp.mainMenu = Self.makeMainMenu()
        Task {
            do {
                start(with: try await Self.openStore { try Self.storeLocation() })
            } catch {
                Log.app.fault("Could not open the history store: \(error.localizedDescription)")
                presentStoreError(error)
            }
        }
    }

    /// The app opens the store off the main thread because the store can migrate the whole history
    /// to a new schema. The rest of the app starts when the store is ready.
    nonisolated static func openStore(at location: @escaping @Sendable () throws -> StoreLocation) async throws -> ClipStore {
        try await Task.detached(priority: .userInitiated) { try ClipStore(location: location()) }.value
    }

    /// The history lives in Application Support. A debug build can use another location, so a test
    /// run of the app never opens the real history.
    nonisolated static func storeLocation(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> StoreLocation {
        #if DEBUG
        if let root = environment[storeRootVariable], !root.isEmpty {
            return StoreLocation(root: URL(fileURLWithPath: root, isDirectory: true))
        }
        #endif
        return try .applicationSupport()
    }

    nonisolated static let storeRootVariable = "CLIPDECK_STORE_ROOT"

    /// ClipDeck watches and writes the general pasteboard. A debug build can use a named
    /// pasteboard, so a test run of the app does not read or replace what the user copied.
    nonisolated static func pasteboardName(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NSPasteboard.Name? {
        #if DEBUG
        if let name = environment[pasteboardVariable], !name.isEmpty {
            return NSPasteboard.Name(name)
        }
        #endif
        return nil
    }

    nonisolated static let pasteboardVariable = "CLIPDECK_PASTEBOARD"

    private func start(with store: ClipStore) {
        self.store = store
        // Sparkle reads SUFeedURL and SUPublicEDKey from Info.plist and schedules its own checks.
        let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.updater = updater
        SettingsWindowController.shared.store = store
        SettingsWindowController.shared.updater = updater
        ClearHistoryWindowController.shared.store = store

        let thumbnails = ThumbnailGenerator(store: store)
        let pasteboard = Self.pasteboardName().map(NSPasteboard.init(name:)) ?? .general
        let monitor = PasteboardMonitor(pasteboard: pasteboard) { capture in
            Task { await Self.ingest(capture, store: store, thumbnails: thumbnails) }
        }
        self.monitor = monitor
        let copier = ClipCopier(store: store, monitor: monitor)
        copier.onCopied = { [weak self] item in self?.hud.show(for: item) }
        panel = PanelController(store: store, copier: copier)
        menuBar = MenuBarController(store: store, actions: .init(
            openPanel: { [weak self] in self?.togglePanel() },
            copy: { item in Task { await copier.copy(item) } },
            clearHistory: { ClearHistoryWindowController.shared.show() },
            openSettings: { SettingsWindowController.shared.show() }
        ), updater: updater)

        registerSavedHotkey()
        observeHotkeyChanges()

        Task { await Self.openSession(store) }
        monitor.start()
        WelcomeWindowController.shared.showIfFirstLaunch()
        if opensSettingsOnStart { SettingsWindowController.shared.show() }
        Log.app.info("ClipDeck started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        hotkeys.tearDown()
        store?.markCleanShutdown()
    }

    /// When the menu bar icon is hidden, reopen the app to access it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        UserDefaults.standard.set(true, forKey: Constants.showMenuBarIconKey)
        if store == nil {
            opensSettingsOnStart = true
        } else {
            SettingsWindowController.shared.show()
        }
        return true
    }

    func togglePanel() {
        panel?.toggle()
    }

    /// It applies the saved storage limit on every launch. If the last session was killed or
    /// crashed, it then repairs the files and the byte counter. A normal launch skips the repair.
    private nonisolated static func openSession(_ store: ClipStore) async {
        do {
            let removed = try await store.setStorageBudget(StorageBudget.load(from: .standard)?.bytes)
            if removed > 0 { await postHistoryChange() }
            if try await store.beginSession() == false {
                let orphans = try await store.collectGarbage()
                Log.store.info("Recovered from an unclean shutdown; removed \(orphans) orphaned files")
            }
        } catch {
            Log.store.error("Could not open the session: \(error.localizedDescription)")
        }
    }

    /// Stores a capture and tells the app what changed. It reports the history after the insert,
    /// then the thumbnail and history again once the thumbnail is saved.
    nonisolated static func ingest(_ capture: Capture, store: ClipStore, thumbnails: ThumbnailGenerator) async {
        do {
            _ = try await store.insert(capture)
            await postHistoryChange()
            // A bump retries thumbnail creation if it failed or never happened. The generator
            // returns immediately if the file already exists.
            if capture.kind != .text, await thumbnails.generate(for: capture) {
                await postThumbnailChange(for: capture.hash)
            }
        } catch {
            Log.store.error("Could not store a capture: \(error.localizedDescription)")
        }
    }

    private static func postHistoryChange() {
        NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
    }

    /// A saved thumbnail tells the rows on screen to load it. It also increases the stored byte
    /// count and can remove the oldest items, so the history change comes afterward.
    private static func postThumbnailChange(for hash: String) {
        NotificationCenter.default.post(name: .clipThumbnailDidChange, object: hash)
        postHistoryChange()
    }

    /// The manager registers the saved shortcut. When the system rejects it, the manager uses the
    /// last working shortcut or the default. `registerSavedHotkey` then saves the fallback, so the
    /// next launch uses it.
    private func registerSavedHotkey() {
        guard !hotkeys.register(HotkeyConfig.load(from: .standard)), let fallback = hotkeys.current else { return }
        fallback.save(to: .standard)
    }

    private func observeHotkeyChanges() {
        let center = NotificationCenter.default
        let register: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.registerSavedHotkey() }
        }
        observers = [
            center.addObserver(forName: .hotkeyDidChange, object: nil, queue: .main, using: register),
            center.addObserver(forName: .hotkeyRecordingDidEnd, object: nil, queue: .main, using: register),
            center.addObserver(forName: .hotkeyRecordingDidBegin, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hotkeys.unregister() }
            },
        ]
    }

    /// While ClipDeck is in the Dock, its menu bar shows the app, File, Edit, and Window menus.
    /// File supports Command-W, and Edit supports the text fields. A menu bar app has no menus by
    /// default, so the standard shortcuts otherwise do nothing in Settings.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: Constants.appName)
        app.addItem(withTitle: "About \(Constants.appName)", action: #selector(showAbout), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings\u{2026}", action: #selector(showSettings), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(Constants.appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(Constants.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: Constants.appName, action: nil, keyEquivalent: "").submenu = app

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window
        return main
    }

    @objc private func showAbout() {
        SettingsWindowController.shared.show(.about)
    }

    @objc private func showSettings() {
        SettingsWindowController.shared.show()
    }

    /// Without its history, ClipDeck has nothing to show, so the alert's only option is to quit. An
    /// accessory app's alert opens behind other windows unless the app activates first.
    private func presentStoreError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "ClipDeck can't open your clipboard history."
        alert.informativeText = Self.storeErrorExplanation(for: error)
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        NSApp.activate()
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// This is the alert's second paragraph. The error describes itself, and the alert adds only
    /// what opening ClipDeck again can do.
    nonisolated static func storeErrorExplanation(for error: Error) -> String {
        let text = error.explanation
        switch reopening(after: error) {
        case .cannotHelp: return text
        case .helpsAfterAdvice: return text + " Then open ClipDeck again."
        case .mayHelp: return text + " Quit ClipDeck. Open it again."
        }
    }

    enum Reopening {
        /// The error either says what to do, or nothing can be done here.
        case cannotHelp
        /// The error ends with advice, and ClipDeck opens once the user has followed it.
        case helpsAfterAdvice
        case mayHelp
    }

    nonisolated static func reopening(after error: Error) -> Reopening {
        if let error = error as? StoreError {
            switch error {
            case .newerSchema: return .cannotHelp
            }
        }
        // The system's own wording names the cause. Reopening does not remove it.
        switch (error as? CocoaError)?.code {
        case .fileWriteNoPermission, .fileReadNoPermission, .fileWriteOutOfSpace, .fileWriteVolumeReadOnly:
            return .cannotHelp
        default:
            return error.advice == nil ? .mayHelp : .helpsAfterAdvice
        }
    }

    private static var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }
}

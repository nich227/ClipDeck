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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app. They must never touch the real history.
        guard !Self.isRunningUnitTests else { return }
        NSApp.mainMenu = Self.makeMainMenu()

        let store: ClipStore
        do {
            store = try ClipStore(location: .applicationSupport())
        } catch {
            Log.app.fault("Could not open the history store: \(error.localizedDescription)")
            presentStoreError(error)
            return
        }
        self.store = store
        // Sparkle reads SUFeedURL and SUPublicEDKey from Info.plist and schedules its own checks.
        let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.updater = updater
        SettingsWindowController.shared.store = store
        SettingsWindowController.shared.updater = updater
        ClearHistoryWindowController.shared.store = store

        let thumbnails = ThumbnailGenerator(store: store)
        let monitor = PasteboardMonitor { capture in
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
        Log.app.info("ClipDeck started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        hotkeys.tearDown()
        store?.markCleanShutdown()
    }

    /// Reopen the app to access it when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        UserDefaults.standard.set(true, forKey: Constants.showMenuBarIconKey)
        SettingsWindowController.shared.show()
        return true
    }

    func togglePanel() {
        panel?.toggle()
    }

    /// It applies the saved storage limit and then repairs the files and byte counter if the last
    /// session was killed or crashed. It skips both steps on a normal launch.
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

    private nonisolated static func ingest(_ capture: Capture, store: ClipStore, thumbnails: ThumbnailGenerator) async {
        do {
            _ = try await store.insert(capture)
            await postHistoryChange()
            // A bump retries thumbnail creation if it failed or never happened. The generator
            // returns immediately if the file already exists.
            if capture.kind != .text, await thumbnails.generate(for: capture) {
                await postHistoryChange()
            }
        } catch {
            Log.store.error("Could not store a capture: \(error.localizedDescription)")
        }
    }

    private static func postHistoryChange() {
        NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
    }

    /// The manager registers the saved shortcut. When the system rejects the saved shortcut, the
    /// manager uses the last working shortcut and saves it for the next launch.
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

    /// The menu bar ClipDeck shows while it is in the Dock: the app menu, Edit for the text
    /// fields, and Window for Command-W. A menu bar app has none by default, so without this the
    /// standard shortcuts do nothing in Settings.
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
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
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

    private func presentStoreError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "ClipDeck can't open your clipboard history."
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }

    private static var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }
}

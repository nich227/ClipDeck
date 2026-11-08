import AppKit
import Carbon
import SwiftUI

/// A floating panel takes keyboard focus without activating ClipDeck, so the user's current app
/// stays frontmost and receives the paste.
final class DeckPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Constants.Panel.width, height: Constants.Panel.height),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let viewModel: HistoryViewModel
    private let copier: ClipCopier
    private var panel: DeckPanel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var historyObserver: ObserverToken?

    init(store: ClipStore, copier: ClipCopier) {
        self.copier = copier
        self.viewModel = HistoryViewModel(store: store)
        super.init()
        historyObserver = ObserverToken(NotificationCenter.default.addObserver(
            forName: .clipHistoryDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewModel.historyDidChange() }
        })
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(frameOnMouseScreen(), display: false)
        viewModel.panelWillShow()
        panel.makeKeyAndOrderFront(nil)
        installEventMonitors()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        removeEventMonitors()
        panel.orderOut(nil)
        viewModel.panelDidHide()
    }

    /// The panel copies the selection back with its original types, then closes. The user pastes
    /// the selection. If there is no selection to copy, the panel stays open to show that it copied
    /// nothing.
    func copySelection() {
        guard let item = viewModel.selectedItem else { return }
        Task {
            guard await copier.copy(item) else { return }
            hide()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func makePanel() -> DeckPanel {
        let panel = DeckPanel()
        panel.delegate = self
        let root = PanelView(viewModel: viewModel, onCopy: { [weak self] in self?.copySelection() })
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: Constants.Panel.width, height: Constants.Panel.height)
        host.autoresizingMask = [.width, .height]
        // The window is clear, and the glass is the panel's only surface. The container clips
        // everything to the same corners, so the window's square frame never shows.
        let glass = NSGlassEffectView(frame: host.frame)
        glass.cornerRadius = Radius.lg
        glass.style = .regular
        glass.contentView = host
        glass.autoresizingMask = [.width, .height]
        let clip = NSView(frame: host.frame)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Radius.lg
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.addSubview(glass)
        panel.contentView = clip
        return panel
    }

    private func frameOnMouseScreen() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: Constants.Panel.width, height: Constants.Panel.height)
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - visible.height * Constants.Panel.topInset - size.height
        )
        return NSRect(origin: origin, size: size)
    }

    // MARK: - Keyboard and clicks

    private func installEventMonitors() {
        removeEventMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
        // A non-activating panel does not always lose key status when the user clicks another app.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func removeEventMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        // While an input method composes Japanese or Chinese text, Return commits the composition,
        // so the field editor keeps Return.
        let isComposing = (panel?.firstResponder as? NSTextView)?.hasMarkedText() == true
        switch Int(event.keyCode) {
        case kVK_DownArrow where !isComposing:
            viewModel.moveSelection(by: 1)
        case kVK_UpArrow where !isComposing:
            viewModel.moveSelection(by: -1)
        case kVK_Return where !isComposing, kVK_ANSI_KeypadEnter where !isComposing:
            copySelection()
        case kVK_Escape where !isComposing:
            hide()
        default:
            return false
        }
        return true
    }
}

/// When released, it removes a block-based notification observer.
final class ObserverToken {
    private let observer: NSObjectProtocol
    private let center: NotificationCenter

    init(_ observer: NSObjectProtocol, center: NotificationCenter = .default) {
        self.observer = observer
        self.center = center
    }

    deinit {
        center.removeObserver(observer)
    }
}

import AppKit
import SwiftUI

/// The first-launch window that asks for file access, one row per protected location. It shows
/// once, when nothing has been asked yet, and again from Settings on request.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    private var window: NSWindow?
    private let model = FileAccessModel()

    /// Shows the window on a first launch. Returns whether it was shown.
    @discardableResult
    func showIfFirstLaunch() -> Bool {
        guard !UserDefaults.standard.bool(forKey: Constants.welcomeShownKey) else { return false }
        show()
        return true
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        Task { await model.refresh() }
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        DockPresence.shared.windowDidOpen(window)
    }

    func close() {
        UserDefaults.standard.set(true, forKey: Constants.welcomeShownKey)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Constants.welcomeShownKey)
        if let window { DockPresence.shared.windowDidClose(window) }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !window.isVisible else { return }
            window.contentViewController = nil
            self.window = nil
        }
    }

    private func makeWindow() -> NSWindow {
        let view = WelcomeView(model: model) { [weak self] in self?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to ClipDeck"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

/// The state of every access, refreshed on appear and after each grant.
@MainActor
final class FileAccessModel: ObservableObject {
    @Published var states: [FileAccess: FileAccessState] = [:]
    @Published var requesting: FileAccess?

    var allFoldersGranted: Bool {
        FileAccess.allCases.filter { !$0.opensSystemSettings }.allSatisfy { states[$0] == .granted }
    }

    func refresh() async {
        for access in FileAccess.allCases {
            states[access] = await FileAccessAuthorization.state(of: access)
        }
    }

    func request(_ access: FileAccess) async {
        requesting = access
        states[access] = await FileAccessAuthorization.request(access)
        requesting = nil
    }

    /// Asks for each folder in turn, so the system shows one prompt at a time.
    func requestAllFolders() async {
        for access in FileAccess.allCases where !access.opensSystemSettings && states[access] != .granted {
            await request(access)
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: FileAccessModel
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: Space.lg) {
            VStack(spacing: Space.xs) {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Palette.accent)
                Text(Constants.appName)
                    .deckFont(.wordmark)
                Text("ClipDeck keeps a link to each file you copy. To show those files, it needs access to the folders they're in. You can grant access now or when ClipDeck first asks.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }

            VStack(spacing: 0) {
                ForEach(FileAccess.allCases) { access in
                    row(for: access)
                    if access != FileAccess.allCases.last {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Palette.surface1))

            HStack {
                Button("Grant All Folder Access") { Task { await model.requestAllFolders() } }
                    .disabled(model.allFoldersGranted || model.requesting != nil)
                Spacer()
                Button(model.allFoldersGranted ? "Done" : "Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    private func row(for access: FileAccess) -> some View {
        let state = model.states[access] ?? .undetermined
        return HStack(spacing: Space.sm) {
            Image(systemName: access.systemImage)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Palette.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(access.title)
                Text(access.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch state {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .accessibilityLabel("\(access.title) access granted")
            case .denied, .undetermined:
                Button(access.opensSystemSettings ? "Open Settings\u{2026}" : (state == .denied ? "Open Settings\u{2026}" : "Grant\u{2026}")) {
                    Task {
                        if state == .denied, let url = access.settingsURL {
                            NSWorkspace.shared.open(url)
                        } else {
                            await model.request(access)
                        }
                    }
                }
                .controlSize(.small)
                .disabled(model.requesting != nil)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }
}

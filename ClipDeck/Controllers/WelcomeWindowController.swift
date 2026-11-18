import AppKit
import SwiftUI

/// The window asks for file access on first launch and shows one row for each protected location.
/// It appears once before any access request, and users can open it again from Settings.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    private var window: NSWindow?
    private let model = FileAccessModel()

    /// Shows the window on first launch. Returns whether it was shown.
    @discardableResult
    func showIfFirstLaunch() -> Bool {
        guard !UserDefaults.standard.bool(forKey: Constants.welcomeShownKey) else { return false }
        show()
        return true
    }

    func show() {
        // After the first launch, Settings opens the same window for file access review.
        model.windowWillOpen(isFirstLaunch: !UserDefaults.standard.bool(forKey: Constants.welcomeShownKey))
        let window = self.window ?? makeWindow()
        self.window = window
        window.title = model.isFirstLaunch ? "Welcome to ClipDeck" : "File Access"
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
        // The view shows the name, so the title bar does not repeat it.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

/// The state of every access refreshes when the view appears and after each grant.
@MainActor
final class FileAccessModel: ObservableObject {
    @Published var states: [FileAccess: FileAccessState] = [:]
    @Published var requesting: FileAccess?
    @Published var isFirstLaunch = true
    /// The marks for accesses granted while the window is open draw on. An access already granted
    /// when the window opens shows a still mark.
    @Published var justGranted: Set<FileAccess> = []

    /// The saved states can be out of date when the window opens again. Thus, the first refresh
    /// records only what is true now.
    private var awaitsBaseline = true

    /// Every mark starts still. A grant made since the window last closed does not count as new
    /// here.
    func windowWillOpen(isFirstLaunch: Bool) {
        self.isFirstLaunch = isFirstLaunch
        justGranted = []
        awaitsBaseline = true
    }

    var allFoldersGranted: Bool {
        FileAccess.allCases.filter { !$0.opensSystemSettings }.allSatisfy { states[$0] == .granted }
    }

    func refresh() async {
        var fresh: [FileAccess: FileAccessState] = [:]
        for access in FileAccess.allCases {
            fresh[access] = await FileAccessAuthorization.state(of: access)
        }
        record(fresh)
    }

    /// A refresh read provides the states. The first state update after the window opens does not
    /// draw a mark.
    func record(_ fresh: [FileAccess: FileAccessState]) {
        apply(fresh, drawsOn: !awaitsBaseline)
        awaitsBaseline = false
    }

    func request(_ access: FileAccess) async {
        requesting = access
        apply([access: await FileAccessAuthorization.request(access)])
        requesting = nil
    }

    /// This records new states. An access counts as just granted only when it was known not to be
    /// granted before. It must also be the only grant in the batch, so one mark moves at a time. An
    /// access that loses its grant can draw its mark again later.
    func apply(_ fresh: [FileAccess: FileAccessState], drawsOn: Bool = true) {
        let granted = fresh.filter { access, state in
            guard drawsOn, let known = states[access] else { return false }
            return known != .granted && state == .granted
        }
        for (access, state) in fresh {
            states[access] = state
            if state != .granted { justGranted.remove(access) }
        }
        if granted.count == 1, let access = granted.keys.first {
            justGranted.insert(access)
        }
    }

    /// This method requests each folder in turn, so the system shows one prompt at a time.
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
                    .frame(width: Glyph.mark, height: Glyph.mark)
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text(Constants.appName)
                    .deckFont(.wordmark)
                    .accessibilityAddTraits(.isHeader)
                Text("ClipDeck keeps a link to each file you copy. To show a file's name and thumbnail, it needs access to the folder that contains the file. Grant access now, or macOS asks the first time you copy a file from each folder.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: SettingsSection.textMeasure)
            }

            VStack(spacing: 0) {
                ForEach(FileAccess.allCases) { access in
                    row(for: access)
                    if access != FileAccess.allCases.last {
                        Divider().padding(.leading, Self.iconColumn + Space.md + Space.sm)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Palette.surface1))

            HStack {
                Button("Grant All Folder Access\u{2026}") { Task { await model.requestAllFolders() } }
                    .disabled(model.allFoldersGranted || model.requesting != nil)
                Spacer()
                Button(model.isFirstLaunch && !model.allFoldersGranted ? "Continue" : "Done", action: onContinue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding([.horizontal, .bottom], Space.xl)
        .padding(.top, Space.xs)
        .frame(width: Self.width)
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    private func row(for access: FileAccess) -> some View {
        let state = model.states[access] ?? .undetermined
        let opensSettings = access.opensSystemSettings || state == .denied
        return HStack(spacing: Space.sm) {
            Image(systemName: access.systemImage)
                .font(.system(size: Glyph.row, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: Self.iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxxs) {
                Text(access.title)
                Text(state == .denied && !access.opensSystemSettings ? "Access was denied. Allow access in System Settings." : access.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            switch state {
            case .granted:
                // The mark is the row's only color, so that color shows the state.
                Group {
                    if model.justGranted.contains(access) {
                        DeckAnimation(name: Constants.Animations.granted, label: "\(access.title), access granted")
                    } else {
                        DeckAnimation.still(name: Constants.Animations.granted, label: "\(access.title), access granted")
                    }
                }
                .frame(width: Glyph.row, height: Glyph.row)
            case .denied, .undetermined:
                Button(opensSettings ? "Open System Settings" : "Grant\u{2026}") {
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
                .accessibilityLabel(opensSettings ? "Open System Settings for \(access.title)" : "Grant access to \(access.title)")
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }

    private static let width: CGFloat = 520
    /// The symbols sit in one column, so the titles line up even when the symbols have different
    /// widths.
    private static let iconColumn: CGFloat = Space.xxl
}

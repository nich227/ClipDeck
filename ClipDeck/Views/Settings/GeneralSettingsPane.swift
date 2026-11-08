import Carbon
import ServiceManagement
import SwiftUI

struct GeneralSettingsPane: View {
    @AppStorage(Constants.showMenuBarIconKey) private var showMenuBarIcon = true
    @AppStorage(Constants.showCopyConfirmationKey) private var showCopyConfirmation = true
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Keyboard Shortcut") {
                HotkeyRecorder()
            }

            Section("ClipDeck") {
                Toggle(isOn: Binding(get: { loginStatus == .enabled }, set: setLaunchAtLogin)) {
                    SettingLabel("Open at Login", detail: loginDetail)
                }

                Toggle(isOn: $showMenuBarIcon) {
                    SettingLabel(
                        "Show in Menu Bar",
                        detail: showMenuBarIcon ? nil : "To show these settings again, open ClipDeck from your Applications folder."
                    )
                }

                Toggle(isOn: $showCopyConfirmation) {
                    SettingLabel("Show Confirmation When Copying", detail: "A brief confirmation appears at the top of the screen.")
                }
            }

            Section("Privacy") {
                LabeledContent {
                    Button("Review\u{2026}") { WelcomeWindowController.shared.show() }
                        .accessibilityIdentifier("reviewFileAccess")
                } label: {
                    SettingLabel("File Access", detail: "Choose which folders ClipDeck can show files from.")
                }
            }
        }
        .settingsPane(.general)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    private var loginDetail: String? {
        if let loginError { return loginError }
        if loginStatus == .requiresApproval { return "To allow ClipDeck to open at login, go to System Settings > General > Login Items & Extensions." }
        return nil
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            Log.app.error("Login item change failed: \(error.localizedDescription)")
        }
        loginStatus = SMAppService.mainApp.status
    }
}

/// Click. Then press the new shortcut. The system refuses combinations already used by the system
/// or by every app, and gives the reason. Press Escape to cancel.
private struct HotkeyRecorder: View {
    @State private var config = HotkeyConfig.load(from: .standard)
    @State private var isRecording = false
    @State private var message: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            LabeledContent {
                Button {
                    isRecording ? stop() : start()
                } label: {
                    Text(isRecording ? "Type shortcut" : config.display)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(isRecording ? Palette.accent : Color.primary)
                        .frame(minWidth: 132)
                        .padding(.vertical, Space.xxs)
                }
                .accessibilityLabel(isRecording ? "Recording shortcut" : "Shortcut \(config.spokenDisplay)")
                .accessibilityHint("Click, then type a new shortcut. Press Escape to cancel.")
            } label: {
                SettingLabel("Show ClipDeck", detail: "Press this shortcut in any app to show or hide ClipDeck.")
            }

            if let message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Palette.danger)
            }

            if !isRecording, config != .default {
                HStack {
                    Text("The default shortcut is \(HotkeyConfig.default.display).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Default") { save(.default) }
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, Space.xxs)
        .onDisappear(perform: stop)
    }

    private func start() {
        message = nil
        isRecording = true
        NotificationCenter.default.post(name: .hotkeyRecordingDidBegin, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { handle(event) }
            return consumed ? nil : event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        NotificationCenter.default.post(name: .hotkeyRecordingDidEnd, object: nil)
    }

    /// Returns true if the recorder used the key press.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = UInt32(event.keyCode)
        if keyCode == UInt32(kVK_Escape), flags.intersection([.command, .option, .control, .shift]).isEmpty {
            stop()
            return true
        }
        let modifiers = HotkeyConfig.carbonModifiers(from: flags)
        let candidate = HotkeyConfig(
            keyCode: keyCode,
            modifiers: modifiers,
            keyLabel: HotkeyConfig.keyLabel(keyCode: keyCode, characters: event.charactersIgnoringModifiers)
        )
        switch HotkeyConfig.validate(keyCode: keyCode, modifiers: modifiers) {
        case .needsModifier:
            message = "The shortcut must include Command, Option, or Control."
        case .reserved(let name):
            message = "\(candidate.display) is already used for \(name). Try a different shortcut."
        case .valid:
            // ClipDeck releases its own shortcut while recording, so a refusal here means another
            // app holds the combination.
            guard HotkeyManager.isAvailable(candidate) else {
                message = "\(candidate.display) is already used by another app. Try a different shortcut."
                return true
            }
            save(candidate)
            stop()
        }
        return true
    }

    private func save(_ newConfig: HotkeyConfig) {
        config = newConfig
        message = nil
        newConfig.save(to: .standard)
        // While recording, `stop()` posts the end of the recording. This post registers the saved
        // shortcut, so a second post here would register it twice.
        if !isRecording {
            NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        }
    }
}

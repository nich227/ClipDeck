import AppKit
import Carbon

/// The global shortcut uses Carbon's hot key API. It needs no Accessibility permission and costs
/// nothing while idle because the system calls back only when the combination is pressed.
@MainActor
final class HotkeyManager {
    private nonisolated static let signature: OSType = 0x4344_4B31
    private nonisolated static let pressID: UInt32 = 1
    private nonisolated static let probeID: UInt32 = 2

    private let onPress: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var current: HotkeyConfig?
    /// We keep the last registered shortcut across `unregister()` so that the system can fall back
    /// to it if a change fails.
    private var lastWorking: HotkeyConfig?

    init(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
    }

    /// Registers `config`. If the system refuses that configuration, ClipDeck registers the last
    /// working shortcut (or the default) again, so a shortcut remains registered. The operation
    /// returns false.
    @discardableResult
    func register(_ config: HotkeyConfig) -> Bool {
        installHandlerIfNeeded()
        unregister()
        if attach(config) { return true }
        let fallback = lastWorking ?? .default
        if fallback != config, attach(fallback) {
            Log.hotkey.notice("Fell back to shortcut \(fallback.display, privacy: .public)")
        }
        return false
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        current = nil
    }

    /// Calling this on quit releases the shortcut and the event handler.
    func tearDown() {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    /// Returns true if the system would accept `config` right now. The method registers it under a
    /// separate ID and immediately releases it, so the system state does not change.
    static func isAvailable(_ config: HotkeyConfig) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: probeID)
        let status = RegisterEventHotKey(config.keyCode, config.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        UnregisterEventHotKey(ref)
        return true
    }

    fileprivate func handlePress() {
        onPress()
    }

    private func attach(_ config: HotkeyConfig) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.pressID)
        let status = RegisterEventHotKey(config.keyCode, config.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.hotkey.error("RegisterEventHotKey failed for \(config.display, privacy: .public) with status \(status)")
            return false
        }
        hotKeyRef = ref
        current = config
        lastWorking = config
        Log.hotkey.info("Registered shortcut \(config.display, privacy: .public)")
        return true
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let read = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed
            )
            guard read == noErr, pressed.signature == HotkeyManager.signature, pressed.id == HotkeyManager.pressID else {
                return OSStatus(eventNotHandledErr)
            }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            // The application event target dispatches on the main thread.
            MainActor.assumeIsolated { manager.handlePress() }
            return noErr
        }, 1, &eventType, context, &handlerRef)
        if status != noErr {
            Log.hotkey.error("InstallEventHandler failed with status \(status)")
        }
    }
}

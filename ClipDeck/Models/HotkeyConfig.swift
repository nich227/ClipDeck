import AppKit
import Carbon

/// The panel shortcut consists of a Carbon key code, a modifier mask, and the key's printed label.
struct HotkeyConfig: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let `default` = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_C),
        modifiers: UInt32(cmdKey | shiftKey),
        keyLabel: "C"
    )

    /// These are the modifier symbols in the order that macOS menus print them.
    var display: String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "\u{2303}" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "\u{2325}" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "\u{21E7}" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "\u{2318}" }
        return symbols + keyLabel
    }

    var spokenDisplay: String {
        var words: [String] = []
        if modifiers & UInt32(controlKey) != 0 { words.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { words.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { words.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { words.append("Command") }
        words.append(keyLabel)
        return words.joined(separator: " ")
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    // MARK: - Validation

    enum Validation: Equatable {
        case valid
        /// Shift alone types a capital letter, so a shortcut needs Command, Option or Control.
        case needsModifier
        case reserved(String)
    }

    static func validate(keyCode: UInt32, modifiers: UInt32) -> Validation {
        let strong = UInt32(cmdKey | optionKey | controlKey)
        guard modifiers & strong != 0 else { return .needsModifier }
        if let name = reserved[Combo(keyCode: keyCode, modifiers: modifiers)] { return .reserved(name) }
        return .valid
    }

    private struct Combo: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32

        init(keyCode: Int, modifiers: Int) {
            self.keyCode = UInt32(keyCode)
            self.modifiers = UInt32(modifiers)
        }

        init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }
    }

    private static let reserved: [Combo: String] = {
        let cmd = cmdKey
        let cmdShift = cmdKey | shiftKey
        let cmdOption = cmdKey | optionKey
        let cmdControl = cmdKey | controlKey
        let entries: [(Int, Int, String)] = [
            (kVK_ANSI_C, cmd, "Copy"),
            (kVK_ANSI_V, cmd, "Paste"),
            (kVK_ANSI_X, cmd, "Cut"),
            (kVK_ANSI_Z, cmd, "Undo"),
            (kVK_ANSI_A, cmd, "Select All"),
            (kVK_ANSI_Q, cmd, "Quit"),
            (kVK_ANSI_W, cmd, "Close Window"),
            (kVK_ANSI_F, cmd, "Find"),
            (kVK_ANSI_H, cmd, "Hide"),
            (kVK_ANSI_M, cmd, "Minimize"),
            (kVK_ANSI_N, cmd, "New"),
            (kVK_ANSI_O, cmd, "Open"),
            (kVK_ANSI_P, cmd, "Print"),
            (kVK_ANSI_S, cmd, "Save"),
            (kVK_ANSI_T, cmd, "New Tab"),
            (kVK_ANSI_Comma, cmd, "Settings"),
            (kVK_ANSI_Grave, cmd, "Cycle Windows"),
            (kVK_Tab, cmd, "App Switcher"),
            (kVK_Space, cmd, "Spotlight"),
            (kVK_ANSI_Z, cmdShift, "Redo"),
            (kVK_ANSI_Q, cmdShift, "Log Out"),
            (kVK_ANSI_3, cmdShift, "Screenshot"),
            (kVK_ANSI_4, cmdShift, "Screenshot Selection"),
            (kVK_ANSI_5, cmdShift, "Screenshot Toolbar"),
            (kVK_Escape, cmdOption, "Force Quit"),
            (kVK_ANSI_D, cmdOption, "Show or Hide the Dock"),
            (kVK_ANSI_H, cmdOption, "Hide Others"),
            (kVK_Space, cmdOption, "Finder Search"),
            (kVK_ANSI_Q, cmdControl, "Lock Screen"),
            (kVK_ANSI_F, cmdControl, "Full Screen"),
            (kVK_Space, cmdControl, "Emoji and Symbols"),
            (kVK_Space, controlKey, "Input Sources"),
        ]
        var table: [Combo: String] = [:]
        for (keyCode, modifiers, name) in entries {
            table[Combo(keyCode: keyCode, modifiers: modifiers)] = name
        }
        return table
    }()

    // MARK: - Key labels

    /// The printed label for a named key is its name. For all other keys, the label is the
    /// character the key types without modifiers.
    static func keyLabel(keyCode: UInt32, characters: String?) -> String {
        if let name = namedKeys[Int(keyCode)] { return name }
        return (characters ?? "").uppercased()
    }

    private static let namedKeys: [Int: String] = [
        kVK_Return: "\u{21A9}", kVK_Tab: "\u{21E5}", kVK_Space: "Space", kVK_Delete: "\u{232B}",
        kVK_Escape: "\u{238B}", kVK_LeftArrow: "\u{2190}", kVK_RightArrow: "\u{2192}",
        kVK_UpArrow: "\u{2191}", kVK_DownArrow: "\u{2193}",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    // MARK: - Persistence

    static func load(from defaults: UserDefaults) -> HotkeyConfig {
        guard let data = defaults.data(forKey: Constants.hotkeyKey),
              let config = try? JSONDecoder().decode(HotkeyConfig.self, from: data),
              validate(keyCode: config.keyCode, modifiers: config.modifiers) == .valid else {
            return .default
        }
        return config
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Constants.hotkeyKey)
    }
}

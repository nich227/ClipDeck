import Foundation
import os

enum Log {
    static let app = Logger(subsystem: Constants.logSubsystem, category: "App")
    static let store = Logger(subsystem: Constants.logSubsystem, category: "Store")
    static let capture = Logger(subsystem: Constants.logSubsystem, category: "Capture")
    static let hotkey = Logger(subsystem: Constants.logSubsystem, category: "Hotkey")
    static let panel = Logger(subsystem: Constants.logSubsystem, category: "Panel")
    static let thumbnails = Logger(subsystem: Constants.logSubsystem, category: "Thumbnails")
}

extension Notification.Name {
    /// This appears on the main thread after the history adds, bumps, or removes items.
    static let clipHistoryDidChange = Notification.Name("com.kevster.clipdeck.historyDidChange")
    /// It is posted after the user saves a new shortcut outside a recording, such as during a
    /// reset.
    static let hotkeyDidChange = Notification.Name("com.kevster.clipdeck.hotkeyDidChange")
    /// The recorder posts this while it listens, so it can also record the live shortcut.
    static let hotkeyRecordingDidBegin = Notification.Name("com.kevster.clipdeck.hotkeyRecordingDidBegin")
    static let hotkeyRecordingDidEnd = Notification.Name("com.kevster.clipdeck.hotkeyRecordingDidEnd")
}

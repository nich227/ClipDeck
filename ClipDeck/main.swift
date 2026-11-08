import AppKit

// ClipDeck has no SwiftUI scene. The menu bar item, the panel, and the windows are all AppKit
// objects that host SwiftUI views, so the delegate owns the whole lifecycle.
let delegate = MainActor.assumeIsolated { AppDelegate() }
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)

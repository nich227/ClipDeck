import AppKit

/// ClipDeck asks for file access when it first opens. Copied files stay as links. The thumbnail and
/// missing file checks read each file, so each protected folder prompts once when ClipDeck first
/// accesses it. Asking for access up front in one place avoids a surprise prompt when a file is
/// first copied from that folder.
enum FileAccess: String, CaseIterable, Identifiable, Sendable {
    case desktop
    case documents
    case downloads
    case removableVolumes
    case fullDisk

    var id: Self { self }

    var title: String {
        switch self {
        case .desktop: return "Desktop"
        case .documents: return "Documents"
        case .downloads: return "Downloads"
        case .removableVolumes: return "Removable Volumes"
        case .fullDisk: return "Full Disk Access"
        }
    }

    var detail: String {
        switch self {
        case .desktop, .documents, .downloads:
            return "This lets ClipDeck show files you copy from your \(title) folder."
        case .removableVolumes:
            return "This lets ClipDeck show files you copy from external drives."
        case .fullDisk:
            return "This is optional. It lets ClipDeck show files from every folder without asking again."
        }
    }

    var systemImage: String {
        switch self {
        case .desktop: return "menubar.dock.rectangle"
        case .documents: return "doc.text"
        case .downloads: return "arrow.down.circle"
        case .removableVolumes: return "externaldrive"
        case .fullDisk: return "internaldrive"
        }
    }

    /// The user grants folder access through the system prompt. The user grants Full Disk Access
    /// with a switch in System Settings, so that option opens System Settings instead.
    var opensSystemSettings: Bool { self == .fullDisk }

    var settingsURL: URL? {
        let pane = opensSystemSettings ? "Privacy_AllFiles" : "Privacy_FilesAndFolders"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }

    /// Use the folder whose listing triggers the prompt, or use a protected file for Full Disk
    /// Access.
    var probeURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .desktop: return home.appendingPathComponent("Desktop", isDirectory: true)
        case .documents: return home.appendingPathComponent("Documents", isDirectory: true)
        case .downloads: return home.appendingPathComponent("Downloads", isDirectory: true)
        case .removableVolumes: return URL(fileURLWithPath: "/Volumes", isDirectory: true)
        case .fullDisk: return home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        }
    }
}

enum FileAccessState: Equatable, Sendable {
    case granted
    case denied
    /// The system has not asked yet, so a probe would show the prompt.
    case undetermined
}

/// It reads and requests file access. Every call runs off the main thread because a probe that
/// triggers the system prompt blocks until the user answers it.
enum FileAccessAuthorization {
    /// It reports the state without prompting. Listing a protected folder prompts the user the
    /// first time, so it lists the folder only after an access request. Before that, it reports
    /// undetermined.
    static func state(of access: FileAccess) async -> FileAccessState {
        let url = access.probeURL
        if access == .fullDisk {
            return await Task.detached(priority: .utility) { canRead(url) }.value ? .granted : .denied
        }
        guard UserDefaults.standard.bool(forKey: promptedKey(access)) else { return .undetermined }
        return await Task.detached(priority: .utility) { canList(url) }.value ? .granted : .denied
    }

    /// Lists the folder to trigger the system prompt, then records the access request. Returns the
    /// resulting state. For Full Disk Access, it opens System Settings instead.
    @discardableResult
    static func request(_ access: FileAccess) async -> FileAccessState {
        if access.opensSystemSettings {
            if let url = access.settingsURL { _ = await MainActor.run { NSWorkspace.shared.open(url) } }
            return await state(of: access)
        }
        let url = access.probeURL
        let granted = await Task.detached(priority: .userInitiated) { canList(url) }.value
        UserDefaults.standard.set(true, forKey: promptedKey(access))
        return granted ? .granted : .denied
    }

    static func promptedKey(_ access: FileAccess) -> String { "fileAccessPrompted.\(access.rawValue)" }

    private static func canList(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            return true
        } catch {
            return false
        }
    }

    private static func canRead(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
            return true
        } catch {
            return false
        }
    }
}

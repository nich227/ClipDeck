import Darwin
import Foundation

/// This is a snapshot of the mounted volumes, read from the kernel's mount table without touching
/// them. It lets the store check whether a file still exists without blocking on a network volume
/// that has stopped answering.
struct LocalVolumes: Sendable {
    /// This lists the mount points of non-local volumes from longest to shortest.
    let remoteMountPoints: [String]

    static func current() -> LocalVolumes {
        let capacity = getfsstat(nil, 0, MNT_NOWAIT)
        guard capacity > 0 else { return LocalVolumes(remoteMountPoints: []) }
        let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: Int(capacity))
        defer { buffer.deallocate() }
        let byteCount = Int32(MemoryLayout<statfs>.stride * Int(capacity))
        let filled = Int(getfsstat(buffer, byteCount, MNT_NOWAIT))
        var remote: [String] = []
        for index in 0..<max(filled, 0) where buffer[index].f_flags & UInt32(MNT_LOCAL) == 0 {
            remote.append(mountPoint(of: &buffer[index]))
        }
        return LocalVolumes(remoteMountPoints: remote.sorted { $0.count > $1.count })
    }

    private static func mountPoint(of mount: inout statfs) -> String {
        withUnsafeBytes(of: &mount.f_mntonname) { raw in
            let bytes = raw.bindMemory(to: CChar.self)
            let length = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: raw.prefix(length), as: UTF8.self)
        }
    }

    func isRemote(_ path: String) -> Bool {
        remoteMountPoints.contains { mountPoint in
            mountPoint != "/" && (path == mountPoint || path.hasPrefix(mountPoint + "/"))
        }
    }

    /// This is true when the file is gone. The system assumes files on non-local volumes are
    /// present, so a stalled server never delays the list.
    func isMissing(atPath path: String) -> Bool {
        guard !isRemote(path) else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }
}

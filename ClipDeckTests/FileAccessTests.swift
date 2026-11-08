import XCTest
@testable import ClipDeck

final class FileAccessTests: XCTestCase {
    func testEveryAccessHasAProbeAndASettingsPane() {
        for access in FileAccess.allCases {
            XCTAssertFalse(access.title.isEmpty)
            XCTAssertFalse(access.detail.isEmpty)
            XCTAssertNotNil(access.settingsURL, "\(access) has no System Settings link")
            XCTAssertTrue(access.probeURL.isFileURL)
        }
    }

    func testOnlyFullDiskAccessOpensSystemSettings() {
        XCTAssertEqual(FileAccess.allCases.filter(\.opensSystemSettings), [.fullDisk])
        XCTAssertTrue(FileAccess.fullDisk.settingsURL?.absoluteString.hasSuffix("Privacy_AllFiles") == true)
        XCTAssertTrue(FileAccess.desktop.settingsURL?.absoluteString.hasSuffix("Privacy_FilesAndFolders") == true)
    }

    func testFolderProbesAreTheProtectedFolders() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(FileAccess.desktop.probeURL.path, home.appendingPathComponent("Desktop").path)
        XCTAssertEqual(FileAccess.documents.probeURL.path, home.appendingPathComponent("Documents").path)
        XCTAssertEqual(FileAccess.downloads.probeURL.path, home.appendingPathComponent("Downloads").path)
        XCTAssertEqual(FileAccess.removableVolumes.probeURL.path, "/Volumes")
    }

    func testAFolderIsUndeterminedUntilItWasRequested() async {
        let key = FileAccessAuthorization.promptedKey(.downloads)
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.removeObject(forKey: key)
        let state = await FileAccessAuthorization.state(of: .downloads)
        XCTAssertEqual(state, .undetermined, "no probe runs before the user is asked, so no prompt appears from a state read")
    }
}

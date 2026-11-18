import XCTest
@testable import ClipDeck

@MainActor
final class CopyHUDControllerTests: XCTestCase {
    private func item(_ title: String) -> ClipItem {
        ClipItem(
            id: 1, hash: "hash", kind: .text, createdAt: Date(), lastUsed: Date(), title: title, detail: nil,
            preview: title, byteSize: Int64(title.utf8.count), blobType: nil, fileCount: 0, isMissing: false
        )
    }

    /// The pill never opens here because the setting that disables it is on for the whole test.
    func testACopyIsAnnouncedWhenTheConfirmationIsTurnedOff() throws {
        let suite = "ClipDeckTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: Constants.showCopyConfirmationKey)
        var announced: [String] = []
        let hud = CopyHUDController(defaults: defaults) { announced.append($0) }

        hud.show(for: item("hello"))
        XCTAssertEqual(announced, ["Copied hello"], "the setting hides the pill, not the announcement")
    }
}

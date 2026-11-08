import AppKit
import Carbon
import XCTest
@testable import ClipDeck

final class MenuShortcutTests: XCTestCase {
    func testTenRowKeysRunOneThroughNineThenZero() {
        XCTAssertEqual(Constants.Menu.rowKeys, ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
        XCTAssertEqual(Constants.Menu.rowKeys.count, Constants.Menu.recentCount)
    }

    @MainActor
    func testGlobalShortcutBecomesAMenuKeyEquivalent() {
        let item = NSMenuItem(title: "Open ClipDeck", action: nil, keyEquivalent: "")
        MenuBarController.applyShortcut(.default, to: item)
        XCTAssertEqual(item.keyEquivalent, "c")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    }

    @MainActor
    func testEveryModifierCarriesOver() {
        let config = HotkeyConfig(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey), keyLabel: "V")
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        MenuBarController.applyShortcut(config, to: item)
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option, .control, .shift])
    }

    @MainActor
    func testNamedKeysMapToTheCharactersMenusExpect() {
        XCTAssertEqual(MenuBarController.menuKeyEquivalent(for: HotkeyConfig(keyCode: UInt32(kVK_Return), modifiers: 0, keyLabel: "Return")), "\r")
        XCTAssertEqual(MenuBarController.menuKeyEquivalent(for: HotkeyConfig(keyCode: UInt32(kVK_Space), modifiers: 0, keyLabel: "Space")), " ")
        let up = MenuBarController.menuKeyEquivalent(for: HotkeyConfig(keyCode: UInt32(kVK_UpArrow), modifiers: 0, keyLabel: "Up Arrow"))
        XCTAssertEqual(up?.unicodeScalars.first?.value, UInt32(NSUpArrowFunctionKey))
    }

    @MainActor
    func testAKeyTheMenuCannotShowLeavesTheItemAlone() {
        let config = HotkeyConfig(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey), keyLabel: "F5")
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        MenuBarController.applyShortcut(config, to: item)
        XCTAssertEqual(item.keyEquivalent, "")
    }
}

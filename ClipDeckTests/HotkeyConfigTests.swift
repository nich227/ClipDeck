import Carbon
import XCTest
@testable import ClipDeck

final class HotkeyConfigTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ClipDeckTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private let cmd = UInt32(cmdKey)
    private let option = UInt32(optionKey)
    private let shift = UInt32(shiftKey)
    private let control = UInt32(controlKey)

    func testDefaultIsShiftCommandC() {
        XCTAssertEqual(HotkeyConfig.default.keyCode, UInt32(kVK_ANSI_C))
        XCTAssertEqual(HotkeyConfig.default.modifiers, cmd | shift)
        XCTAssertEqual(HotkeyConfig.default.display, "\u{21E7}\u{2318}C")
        XCTAssertEqual(HotkeyConfig.default.spokenDisplay, "Shift Command C")
        XCTAssertEqual(HotkeyConfig.validate(keyCode: UInt32(kVK_ANSI_C), modifiers: cmd | shift), .valid)
    }

    func testBareCopyAndPasteAreRefused() {
        XCTAssertEqual(HotkeyConfig.validate(keyCode: UInt32(kVK_ANSI_C), modifiers: cmd), .reserved("Copy"))
        XCTAssertEqual(HotkeyConfig.validate(keyCode: UInt32(kVK_ANSI_V), modifiers: cmd), .reserved("Paste"))
    }

    func testSystemCombosAreRefused() {
        XCTAssertEqual(HotkeyConfig.validate(keyCode: UInt32(kVK_Space), modifiers: cmd), .reserved("Spotlight"))
        XCTAssertEqual(HotkeyConfig.validate(keyCode: UInt32(kVK_Escape), modifiers: cmd | option), .reserved("Force Quit"))
        XCTAssertEqual(HotkeyConfig.validate(keyCode: UInt32(kVK_ANSI_Q), modifiers: cmd | control), .reserved("Lock Screen"))
        XCTAssertEqual(HotkeyConfig.validate(keyCode: UInt32(kVK_ANSI_4), modifiers: cmd | shift), .reserved("Screenshot Selection"))
    }

    func testShortcutNeedsAStrongModifier() {
        XCTAssertEqual(HotkeyConfig.validate(keyCode: UInt32(kVK_ANSI_C), modifiers: 0), .needsModifier)
        XCTAssertEqual(HotkeyConfig.validate(keyCode: UInt32(kVK_ANSI_C), modifiers: shift), .needsModifier)
        XCTAssertEqual(HotkeyConfig.validate(keyCode: UInt32(kVK_ANSI_C), modifiers: control | shift), .valid)
    }

    func testModifierOrderInDisplay() {
        let config = HotkeyConfig(keyCode: UInt32(kVK_ANSI_K), modifiers: cmd | shift | option | control, keyLabel: "K")
        XCTAssertEqual(config.display, "\u{2303}\u{2325}\u{21E7}\u{2318}K")
    }

    func testCarbonModifiersFromEventFlags() {
        XCTAssertEqual(HotkeyConfig.carbonModifiers(from: [.command, .option]), cmd | option)
        XCTAssertEqual(HotkeyConfig.carbonModifiers(from: [.control, .shift]), control | shift)
        XCTAssertEqual(HotkeyConfig.carbonModifiers(from: []), 0)
    }

    func testKeyLabels() {
        XCTAssertEqual(HotkeyConfig.keyLabel(keyCode: UInt32(kVK_ANSI_C), characters: "c"), "C")
        XCTAssertEqual(HotkeyConfig.keyLabel(keyCode: UInt32(kVK_Space), characters: " "), "Space")
        XCTAssertEqual(HotkeyConfig.keyLabel(keyCode: UInt32(kVK_F5), characters: nil), "F5")
    }

    func testEncodeDecodeRoundTrip() throws {
        let config = HotkeyConfig(keyCode: UInt32(kVK_ANSI_K), modifiers: cmd | shift, keyLabel: "K")
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(HotkeyConfig.self, from: data), config)
    }

    func testLoadWithoutSavedValueReturnsDefault() {
        XCTAssertEqual(HotkeyConfig.load(from: defaults), .default)
    }

    func testSaveThenLoad() {
        let config = HotkeyConfig(keyCode: UInt32(kVK_ANSI_K), modifiers: cmd | shift, keyLabel: "K")
        config.save(to: defaults)
        XCTAssertEqual(HotkeyConfig.load(from: defaults), config)
    }

    func testCorruptOrReservedSavedValueFallsBackToDefault() {
        defaults.set(Data("not json".utf8), forKey: Constants.hotkeyKey)
        XCTAssertEqual(HotkeyConfig.load(from: defaults), .default)

        HotkeyConfig(keyCode: UInt32(kVK_ANSI_V), modifiers: cmd, keyLabel: "V").save(to: defaults)
        XCTAssertEqual(HotkeyConfig.load(from: defaults), .default)
    }
}

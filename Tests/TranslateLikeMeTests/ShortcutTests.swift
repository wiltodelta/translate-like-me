import AppKit
import Carbon
import XCTest
@testable import TranslateLikeMe

final class ShortcutTests: XCTestCase {
    func testDisplayDefaultBinding() {
        // The default shortcut: key code 3 = F, modifiers = Command + Option -> "⌥⌘F".
        let mods = Int(cmdKey | optionKey)
        XCTAssertEqual(Shortcut.display(keyCode: 3, modifiers: mods), "⌥⌘F")
    }

    func testDisplayModifierOrderIsFixed() {
        // Symbols are emitted control, option, shift, command regardless of input.
        let mods = Int(cmdKey | controlKey | shiftKey | optionKey)
        XCTAssertEqual(Shortcut.display(keyCode: 17, modifiers: mods), "⌃⌥⇧⌘T")
    }

    func testKeyNameKnownAndUnknown() {
        XCTAssertEqual(Shortcut.keyName(3), "F")
        XCTAssertEqual(Shortcut.keyName(49), "Space")
        XCTAssertEqual(Shortcut.keyName(123), "←")
        XCTAssertEqual(Shortcut.keyName(999), "Key 999")
    }

    func testCarbonModifiersFromFlags() {
        let carbon = Shortcut.carbonModifiers(from: [.command, .option])
        XCTAssertEqual(carbon, UInt32(cmdKey | optionKey))
    }
}

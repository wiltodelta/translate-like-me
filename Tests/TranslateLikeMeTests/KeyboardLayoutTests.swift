import Carbon.HIToolbox
import XCTest
@testable import TranslateLikeMe

final class KeyboardLayoutTests: XCTestCase {
    // Copy and Paste key codes for C and V in each layout; Dvorak - QWERTY Command
    // switches to QWERTY while Command is held.
    @MainActor
    func testCopyAndPasteKeysFollowTheASCIICapableLayout() throws {
        let expected: [String: (copy: CGKeyCode, paste: CGKeyCode)] = [
            "com.apple.keylayout.US": (8, 9),
            "com.apple.keylayout.Dvorak": (34, 47),
            "com.apple.keylayout.DVORAK-QWERTYCMD": (8, 9),
        ]
        for (id, codes) in expected {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
            let source = try XCTUnwrap(sources?.first, id)
            XCTAssertEqual(KeyboardLayout.keyCode(typing: "c", in: source), codes.copy, id)
            XCTAssertEqual(KeyboardLayout.keyCode(typing: "v", in: source), codes.paste, id)
        }
    }
}

import AppKit
import Carbon
import XCTest
@testable import TranslateLikeMe

final class OptionKeyGestureTests: XCTestCase {
    func testEachOptionStartsOnPressAndFinishesOnceOnRelease() {
        for key in [58, 61] {
            var gesture = OptionKeyGesture(keyCode: key)
            XCTAssertEqual(gesture.flagsChanged(keyCode: key, flags: .option), .press)
            XCTAssertEqual(gesture.flagsChanged(keyCode: key, flags: []), .release)
            XCTAssertNil(gesture.flagsChanged(keyCode: key, flags: []))
        }
    }

    func testOppositeOptionDoesNotStartRecording() {
        var gesture = OptionKeyGesture(keyCode: 61)
        XCTAssertNil(gesture.flagsChanged(keyCode: 58, flags: .option))
        XCTAssertNil(gesture.flagsChanged(keyCode: 58, flags: []))
        XCTAssertEqual(gesture.flagsChanged(keyCode: 61, flags: .option), .press)
        XCTAssertEqual(gesture.flagsChanged(keyCode: 61, flags: []), .release)
    }

    func testInterveningActivityCancelsWithoutFinishingButNextHoldWorks() {
        for key in [58, 61] {
            var gesture = OptionKeyGesture(keyCode: key)
            XCTAssertNil(gesture.cancel())
            XCTAssertEqual(gesture.flagsChanged(keyCode: key, flags: .option), .press)
            XCTAssertEqual(gesture.cancel(), .cancel)
            XCTAssertNil(gesture.cancel())
            XCTAssertNil(gesture.flagsChanged(keyCode: key, flags: []))
            XCTAssertEqual(gesture.flagsChanged(keyCode: key, flags: .option), .press)
            XCTAssertEqual(gesture.flagsChanged(keyCode: key, flags: []), .release)
        }
    }

    func testEveryOtherModifierCancelsAndCannotStartAHold() {
        let modifiers: [(Int, NSEvent.ModifierFlags)] = [(55, .command), (56, .shift), (59, .control), (63, .function)]
        for (key, flags) in modifiers {
            var gesture = OptionKeyGesture(keyCode: 61)
            XCTAssertEqual(gesture.flagsChanged(keyCode: 61, flags: .option), .press)
            XCTAssertEqual(gesture.flagsChanged(keyCode: key, flags: flags.union(.option)), .cancel)
            XCTAssertNil(gesture.flagsChanged(keyCode: key, flags: .option))
            XCTAssertNil(gesture.flagsChanged(keyCode: 61, flags: []))
            XCTAssertNil(gesture.flagsChanged(keyCode: key, flags: flags))
            XCTAssertNil(gesture.flagsChanged(keyCode: 61, flags: flags.union(.option)))
            XCTAssertNil(gesture.flagsChanged(keyCode: 61, flags: flags))
            XCTAssertNil(gesture.flagsChanged(keyCode: key, flags: []))
            XCTAssertEqual(gesture.flagsChanged(keyCode: 61, flags: .option), .press)
            XCTAssertEqual(gesture.flagsChanged(keyCode: 61, flags: []), .release)
        }
    }

    func testBothOptionKeysCancelAnActiveHoldAndDoNotStartAnother() {
        var gesture = OptionKeyGesture(keyCode: 61)
        XCTAssertEqual(gesture.flagsChanged(keyCode: 61, flags: .option), .press)
        XCTAssertEqual(gesture.flagsChanged(keyCode: 58, flags: .option), .cancel)
        XCTAssertNil(gesture.flagsChanged(keyCode: 58, flags: .option))
        XCTAssertNil(gesture.flagsChanged(keyCode: 61, flags: []))
        XCTAssertNil(gesture.flagsChanged(keyCode: 58, flags: .option))
        XCTAssertNil(gesture.flagsChanged(keyCode: 61, flags: .option))
        XCTAssertNil(gesture.flagsChanged(keyCode: 58, flags: .option))
        XCTAssertNil(gesture.flagsChanged(keyCode: 61, flags: []))
    }

    func testInstallingWhileOptionIsHeldDoesNotInventAPress() {
        var gesture = OptionKeyGesture(keyCode: 61, initialFlags: .option)
        XCTAssertNil(gesture.flagsChanged(keyCode: 61, flags: .option))
        XCTAssertNil(gesture.flagsChanged(keyCode: 61, flags: []))
        XCTAssertEqual(gesture.flagsChanged(keyCode: 61, flags: [.option, .capsLock]), .press)
        XCTAssertEqual(gesture.flagsChanged(keyCode: 61, flags: .capsLock), .release)
    }

    func testOnlyTheTwoBareOptionBindingsUseThisPathAndHaveReadableLabels() {
        for key in [58, 61] {
            let binding = KeyCombo(keyCode: key, modifiers: Int(optionKey))
            XCTAssertTrue(Shortcut.isOptionOnly(binding))
            XCTAssertEqual(Shortcut.display(binding), key == 58 ? "Left Option" : "Right Option")
            XCTAssertFalse(Shortcut.isOptionOnly(KeyCombo(keyCode: key, modifiers: Int(optionKey | cmdKey))))
            XCTAssertNil(Shortcut.menuKeyEquivalent(binding))
        }
        XCTAssertFalse(Shortcut.isOptionOnly(KeyCombo(keyCode: 2, modifiers: Int(optionKey))))
        XCTAssertFalse(Shortcut.isOptionOnly(KeyCombo(keyCode: 55, modifiers: Int(cmdKey))))
    }
}

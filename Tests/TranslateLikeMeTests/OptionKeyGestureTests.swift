import AppKit
import Carbon
import XCTest
@testable import TranslateLikeMe

final class OptionKeyGestureTests: XCTestCase {
    func testDirectInputStillCancelsThroughTheEventHandler() {
        let types: [NSEvent.EventType] = [.keyDown, .keyUp, .scrollWheel,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        for key in [58, 61] {
            for type in types {
                var gesture = OptionKeyGesture(keyCode: key)
                XCTAssertEqual(gesture.handle(type: .flagsChanged, keyCode: key, flags: .option), .press)
                XCTAssertEqual(gesture.handle(type: type, keyCode: 0, flags: .option), .cancel)
                XCTAssertNil(gesture.handle(type: .flagsChanged, keyCode: key, flags: []))
                XCTAssertEqual(gesture.handle(type: .flagsChanged, keyCode: key, flags: .option), .press)
                XCTAssertEqual(gesture.handle(type: .flagsChanged, keyCode: key, flags: []), .release)
            }
        }
    }

    func testMomentumScrollingDoesNotCancelAnOptionHold() throws {
        let phases: [(Int64, NSEvent.Phase)] = [(1, .began), (2, .changed), (3, .ended)]
        for (raw, phase) in phases {
            let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                              wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0))
            cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: raw)
            let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
            XCTAssertEqual(event.type, .scrollWheel)
            XCTAssertEqual(event.momentumPhase, phase)
            var gesture = OptionKeyGesture(keyCode: 61)
            XCTAssertEqual(gesture.flagsChanged(keyCode: 61, flags: .option), .press)
            XCTAssertNil(gesture.handle(type: event.type, keyCode: 0, flags: event.modifierFlags,
                                        momentumPhase: event.momentumPhase))
            XCTAssertEqual(gesture.flagsChanged(keyCode: 61, flags: []), .release)
        }
    }

    func testEachOptionStartsOnPressAndFinishesOnceOnRelease() {
        for key in [58, 61] {
            var gesture = OptionKeyGesture(keyCode: key)
            XCTAssertEqual(gesture.flagsChanged(keyCode: key, flags: .option), .press)
            XCTAssertEqual(gesture.flagsChanged(keyCode: key, flags: []), .release)
            XCTAssertNil(gesture.flagsChanged(keyCode: key, flags: []))
        }
    }

    func testRepeatedOptionFlagsDoNotCancelAnActiveHold() {
        for key in [58, 61] {
            var gesture = OptionKeyGesture(keyCode: key)
            XCTAssertEqual(gesture.flagsChanged(keyCode: key, flags: .option), .press)
            for flags: NSEvent.ModifierFlags in [.option, [.option, .capsLock], .option] {
                XCTAssertNil(gesture.flagsChanged(keyCode: key, flags: flags),
                             "An unchanged Option hold is not intervening input")
            }
            XCTAssertEqual(gesture.flagsChanged(keyCode: key, flags: []), .release)
            XCTAssertNil(gesture.flagsChanged(keyCode: key, flags: []))
        }
    }

    func testRepeatedFlagsCannotRestartACancelledHold() {
        var gesture = OptionKeyGesture(keyCode: 61)
        XCTAssertEqual(gesture.flagsChanged(keyCode: 61, flags: .option), .press)
        XCTAssertEqual(gesture.cancel(), .cancel)
        XCTAssertNil(gesture.flagsChanged(keyCode: 61, flags: .option))
        XCTAssertNil(gesture.flagsChanged(keyCode: 61, flags: []))
        XCTAssertEqual(gesture.flagsChanged(keyCode: 61, flags: .option), .press)
        XCTAssertEqual(gesture.flagsChanged(keyCode: 61, flags: []), .release)
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

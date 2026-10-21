import CoreAudio
import XCTest
@testable import TranslateLikeMe

final class DictationMicrophoneTests: XCTestCase {
    private let builtIn: AudioDeviceID = 77
    private let usb: AudioDeviceID = 90

    func testNoChoiceFollowsTheSystemInput() {
        XCTAssertEqual(DictationMicrophone.resolve(nil, device: { _ in self.usb }, system: { self.builtIn }), builtIn)
    }

    func testConnectedChoiceIsUsed() {
        let device = DictationMicrophone.resolve("usb-uid", device: { $0 == "usb-uid" ? self.usb : nil },
                                                 system: { self.builtIn })
        XCTAssertEqual(device, usb)
    }

    func testDisconnectedChoiceFallsBackToTheSystemInput() {
        XCTAssertEqual(DictationMicrophone.resolve("usb-uid", device: { _ in nil }, system: { self.builtIn }), builtIn)
    }
}

// The controller owns the choice: it persists it, hands it to the recorder and
// rebuilds the prepared input, never during capture.
@MainActor
final class DictationMicrophoneChoiceTests: XCTestCase {
    func testMicrophoneChoiceRebuildsThePreparedInputAndIsBlockedDuringCapture() async {
        let recorder = ControlledDictationRecorder()
        var saved: [DictationMicrophone?] = []
        let controller = makeController(recorder: recorder) { saved.append($0) }
        controller.restore()
        await controller.operation?.value
        controller.selectMicrophone(usb)
        controller.selectMicrophone(usb)
        controller.selectMicrophone(nil)
        XCTAssertEqual(saved, [usb, nil])
        XCTAssertEqual(recorder.inputs, [nil, "usb-uid", nil])
        XCTAssertEqual(recorder.warmUps, [false, true, true])
        controller.shortcutPressed()
        controller.selectMicrophone(usb)
        XCTAssertEqual(saved, [usb, nil])
        XCTAssertNil(controller.microphone)
        controller.cancel()
    }

    func testMicrophoneChoicePersistsWhileDisabledWithoutPreparingInput() {
        let recorder = ControlledDictationRecorder()
        var saved: [DictationMicrophone?] = []
        makeController(enabled: false, recorder: recorder) {
            saved.append($0)
        }.selectMicrophone(usb)
        XCTAssertEqual(saved, [usb])
        XCTAssertEqual(recorder.inputs, [nil, "usb-uid"])
        XCTAssertTrue(recorder.warmUps.isEmpty)
    }

    private var usb: DictationMicrophone { DictationMicrophone(uid: "usb-uid", name: "USB Microphone") }

    private func makeController(enabled: Bool = true, recorder: ControlledDictationRecorder,
                                save: @escaping (DictationMicrophone?) -> Void) -> DictationController {
        let interaction = DictationInteraction(endCapture: {}, showError: { _ in }, showResult: { _ in })
        return DictationController(enabled: enabled, engine: ControlledDictationEngine(), recorder: recorder,
                                   interaction: interaction, saveModel: { _ in }, saveMicrophone: save)
    }
}

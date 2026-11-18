import CoreAudio
import XCTest
@testable import TranslateLikeMe

final class DictationMicrophoneTests: XCTestCase {
    private let builtIn: AudioDeviceID = 77
    private let usb: AudioDeviceID = 90
    private let secondUSB: AudioDeviceID = 91
    private let airPods: AudioDeviceID = 95
    private let continuity: AudioDeviceID = 82
    private let loopback: AudioDeviceID = 84

    func testNoChoiceFollowsNonBluetoothSystemInputIncludingWiredUSB() {
        XCTAssertEqual(resolve(nil, system: builtIn), builtIn)
        XCTAssertEqual(resolve(nil, system: usb, candidates: [builtIn, usb]), usb)
    }

    func testNoChoiceSkipsBluetoothSystemInputForBuiltInOverContinuityVirtualAndUSB() {
        let chosen = resolve(nil, system: airPods, candidates: [continuity, loopback, usb, builtIn, airPods])
        XCTAssertEqual(chosen, builtIn)
    }

    func testNoChoiceUsesWiredMicrophoneWhenBluetoothIsSystemAndBuiltInIsUnavailable() {
        let chosen = resolve(nil, system: airPods, candidates: [continuity, loopback, airPods, usb, secondUSB])
        XCTAssertEqual(chosen, usb)
    }

    func testNoChoiceFallsBackToBluetoothWhenNoLocalAlternativeExists() {
        let chosen = resolve(nil, system: airPods, candidates: [continuity, loopback, airPods])
        XCTAssertEqual(chosen, airPods)
    }

    func testExplicitChoiceHonorsBluetoothAndWiredSelections() {
        XCTAssertEqual(resolve("airpods-uid", system: builtIn, candidates: [builtIn, airPods]), airPods)
        XCTAssertEqual(resolve("usb-uid", system: builtIn, candidates: [builtIn, usb]), usb)
    }

    func testDisconnectedChoiceBypassesBluetoothSystemInputWhenBuiltInIsAvailable() {
        let chosen = resolve("usb-uid", connected: [builtIn, airPods], system: airPods,
                             candidates: [continuity, builtIn, airPods])
        XCTAssertEqual(chosen, builtIn)
    }

    private func resolve(_ preferred: String?, connected: Set<AudioDeviceID>? = nil,
                         system: AudioDeviceID, candidates: [AudioDeviceID]? = nil) -> AudioDeviceID? {
        let routes: [AudioDeviceID: DictationInputRoute] = [
            builtIn: DictationInputRoute(device: builtIn, uid: "built-in", transport: .builtIn),
            usb: DictationInputRoute(device: usb, uid: "usb-uid", transport: .usb),
            secondUSB: DictationInputRoute(device: secondUSB, uid: "usb-2-uid", transport: .usb),
            airPods: DictationInputRoute(device: airPods, uid: "airpods-uid", transport: .bluetooth),
            continuity: DictationInputRoute(device: continuity, uid: "iphone-uid", transport: .continuity),
            loopback: DictationInputRoute(device: loopback, uid: "loopback-uid", transport: .virtual),
        ]
        let live = connected ?? Set(routes.keys)
        return DictationInputRoute.resolve(
            preferred,
            device: { uid in routes.values.first { $0.uid == uid && live.contains($0.device) }?.device },
            system: { system },
            candidates: { candidates ?? [self.builtIn] },
            snapshot: { live.contains($0) ? routes[$0] : nil }
        )?.device
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

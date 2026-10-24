import XCTest
@testable import TranslateLikeMe

@MainActor
final class DictationRecoveryTests: XCTestCase {
    func testNextHoldRetriesAfterMicrophoneFailureWithoutRecognizingPartialAudio() async {
        for startupFailure in [true, false] {
            let engine = ControlledDictationEngine()
            let recorder = ControlledDictationRecorder()
            let controller = makeController(engine: engine, recorder: recorder)
            controller.restore()
            await controller.operation?.value
            if startupFailure { recorder.startError = .microphone }
            controller.shortcutPressed()
            if !startupFailure { recorder.onEnd?(false) }
            XCTAssertEqual(controller.phase, .failed)
            XCTAssertNotNil(controller.error)
            XCTAssertFalse(recorder.hasAudio)
            XCTAssertTrue(engine.transcribed.isEmpty)
            XCTAssertFalse(TranslationActivity.shared.isBusy)

            recorder.startError = nil
            controller.shortcutReleased()
            controller.shortcutPressed()
            XCTAssertEqual(recorder.starts, 2)
            XCTAssertEqual(recorder.warmUps, [false, true])
            XCTAssertEqual(controller.phase, .starting)
            XCTAssertNil(controller.error)
            guard recorder.starts == 2 else { controller.cancel(); continue }
            controller.shortcutReleased()
            await controller.operation?.value
            XCTAssertEqual(engine.transcribed, [recorder.audio])
            XCTAssertEqual(controller.phase, .ready)
        }
    }

    func testHoldCannotBypassFailedMicrophonePermission() async {
        let recorder = ControlledDictationRecorder()
        recorder.permitted = false
        let controller = makeController(engine: ControlledDictationEngine(), recorder: recorder)
        controller.restore()
        await controller.operation?.value
        XCTAssertEqual(controller.phase, .failed)
        controller.shortcutPressed()
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertEqual(controller.phase, .failed)
    }

    func testHoldCannotBypassFailedModelPreparation() async {
        let engine = ControlledDictationEngine()
        engine.failNextPreparation = true
        let recorder = ControlledDictationRecorder()
        let controller = makeController(engine: engine, recorder: recorder)
        controller.restore()
        await controller.operation?.value
        XCTAssertEqual(controller.phase, .failed)
        controller.shortcutPressed()
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertEqual(controller.phase, .failed)
    }

    private func makeController(engine: ControlledDictationEngine,
                                recorder: ControlledDictationRecorder) -> DictationController {
        DictationController(enabled: true, engine: engine, recorder: recorder,
                            interaction: DictationInteraction(endCapture: {}, showError: { _ in },
                                                              showResult: { _ in }), saveModel: { _ in })
    }
}

import Foundation
import XCTest
@testable import TranslateLikeMe

@MainActor
final class DictationControllerTests: XCTestCase {
    func testCaptureFeedbackPrecedesStartingTheMicrophone() async {
        let engine = ControlledDictationEngine()
        let recorder = ControlledDictationRecorder()
        var feedbackShown = false
        let controller = DictationController(enabled: true, engine: engine, recorder: recorder,
            interaction: DictationInteraction(endCapture: {}, showError: { _ in }, showResult: { _ in }, showCapture: {
                feedbackShown = true
                XCTAssertEqual(recorder.starts, 0)
            }), saveModel: { _ in })
        controller.restore()
        await controller.operation?.value
        XCTAssertEqual(controller.phase, .ready)
        controller.shortcutPressed()
        XCTAssertTrue(feedbackShown)
        XCTAssertEqual(recorder.starts, 1)
        controller.cancel()
    }

    func testRecognitionWaitsForTheRecordingToFinishDraining() async {
        let engine = ControlledDictationEngine()
        let recorder = ControlledDictationRecorder()
        recorder.blockDrain = true
        let controller = makeController(engine: engine, recorder: recorder)
        controller.restore()
        await controller.operation?.value
        controller.shortcutPressed()
        controller.shortcutReleased()
        await recorder.waitForDrain()
        XCTAssertEqual(controller.phase, .recognizing)
        XCTAssertTrue(engine.transcribed.isEmpty)
        recorder.finishDrain()
        await controller.operation?.value
        XCTAssertEqual(engine.transcribed, [recorder.audio])
        XCTAssertFalse(recorder.hasAudio)
    }

    func testCancellationWhileDrainingNeverRecognizesTheDiscardedAudio() async {
        let engine = ControlledDictationEngine()
        let recorder = ControlledDictationRecorder()
        recorder.blockDrain = true
        let controller = makeController(engine: engine, recorder: recorder)
        controller.restore()
        await controller.operation?.value
        controller.shortcutPressed()
        controller.shortcutReleased()
        await recorder.waitForDrain()
        controller.cancel()
        XCTAssertFalse(recorder.hasAudio)
        recorder.finishDrain()
        await controller.operation?.value
        XCTAssertTrue(engine.transcribed.isEmpty)
        XCTAssertEqual(controller.phase, .ready)
    }

    func testTranscriptGoesToDeliveryAndOnlyAnUndeliveredOneIsShown() async {
        for delivered in [true, false] {
            let engine = ControlledDictationEngine()
            engine.transcript = "Привет, world!"
            let recorder = ControlledDictationRecorder()
            var deliveries: [String] = []
            var shown: [String] = []
            let controller = DictationController(enabled: true, engine: engine, recorder: recorder,
                interaction: DictationInteraction(endCapture: {}, showError: { _ in },
                                                  showResult: { shown.append($0) }, deliver: {
                    deliveries.append($0)
                    XCTAssertTrue(TranslationActivity.shared.isBusy, "Capture owns activity through delivery")
                    return delivered
                }), saveModel: { _ in })
            controller.restore()
            await controller.operation?.value
            controller.shortcutPressed()
            controller.shortcutReleased()
            await controller.operation?.value
            XCTAssertEqual(deliveries, ["Привет, world!"])
            XCTAssertEqual(shown, delivered ? [] : ["Привет, world!"])
            XCTAssertEqual(controller.lastResult, "Привет, world!")
            XCTAssertEqual(controller.phase, .ready)
            XCTAssertFalse(TranslationActivity.shared.isBusy)
        }
    }

    func testEvictedModelLoadsAfterReleaseWithoutLosingCapturedAudio() async throws {
        let engine = ControlledDictationEngine()
        let recorder = ControlledDictationRecorder()
        let controller = makeController(engine: engine, recorder: recorder)
        controller.restore()
        await controller.operation?.value
        XCTAssertTrue(engine.loaded)
        engine.blockNextPreparation = true
        controller.releaseForMemoryPressure()
        await engine.waitForUnload()
        XCTAssertFalse(engine.loaded)

        controller.shortcutPressed()
        XCTAssertEqual(recorder.starts, 1, "Capture must start on press, before any model await")
        guard recorder.starts == 1 else {
            controller.cancel()
            await controller.operation?.value
            return
        }
        controller.shortcutReleased()
        XCTAssertEqual(recorder.stops, 1, "A short hold must retain its audio for recognition")
        await engine.waitForPreparation()
        XCTAssertEqual(controller.phase, .recognizing)
        XCTAssertTrue(recorder.hasAudio, "Keep the drained recording while the model loads")
        engine.finishPreparation()
        await controller.operation?.value
        XCTAssertEqual(engine.transcribed, [recorder.audio])
        XCTAssertFalse(recorder.hasAudio)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertNil(controller.error)
    }

    func testCancelledInitialPreparationRestartsBeforeReportingReady() async {
        let engine = ControlledDictationEngine()
        engine.blockNextPreparation = true
        let controller = makeController(engine: engine, recorder: ControlledDictationRecorder())
        controller.restore()
        await engine.waitForPreparation()
        XCTAssertEqual(controller.phase, .preparing)
        let interrupted = controller.operation
        controller.cancel()
        XCTAssertEqual(controller.phase, .cancelling)
        engine.blockNextPreparation = true
        engine.finishPreparation()
        await interrupted?.value
        await engine.waitForPreparation()
        XCTAssertEqual(controller.phase, .preparing)
        XCTAssertFalse(engine.loaded)
        engine.finishPreparation()
        await controller.operation?.value
        XCTAssertEqual(engine.preparations, [true, true])
        XCTAssertTrue(engine.loaded)
        XCTAssertEqual(controller.phase, .ready)
    }

    func testCancellationWhileReloadingNeverRecognizesTheDiscardedRecording() async {
        let engine = ControlledDictationEngine()
        let recorder = ControlledDictationRecorder()
        let controller = makeController(engine: engine, recorder: recorder)
        controller.restore()
        await controller.operation?.value
        controller.releaseForMemoryPressure()
        await engine.waitForUnload()
        engine.blockNextPreparation = true
        controller.shortcutPressed()
        controller.shortcutReleased()
        await engine.waitForPreparation()
        controller.cancel()
        XCTAssertFalse(recorder.hasAudio)
        engine.finishPreparation()
        await controller.operation?.value
        XCTAssertTrue(engine.transcribed.isEmpty)
        XCTAssertEqual(recorder.starts, 1)
        XCTAssertEqual(controller.phase, .ready)
    }

    func testTerminationDoesNotRestartInterruptedPreparation() async {
        let engine = ControlledDictationEngine()
        engine.blockNextPreparation = true
        let controller = makeController(engine: engine, recorder: ControlledDictationRecorder())
        controller.restore()
        await engine.waitForPreparation()
        controller.cancel()
        controller.shutdown()
        engine.finishPreparation()
        await controller.operation?.value
        XCTAssertEqual(engine.preparations, [true])
        XCTAssertFalse(engine.loaded)
    }

    func testFailedRestartOffersRetryInsteadOfReportingReady() async {
        let engine = ControlledDictationEngine()
        engine.blockNextPreparation = true
        let controller = makeController(engine: engine, recorder: ControlledDictationRecorder())
        controller.restore()
        await engine.waitForPreparation()
        let interrupted = controller.operation
        controller.cancel()
        engine.failNextPreparation = true
        engine.finishPreparation()
        await interrupted?.value
        await controller.operation?.value
        XCTAssertEqual(engine.preparations, [true, true])
        XCTAssertFalse(engine.loaded)
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertTrue(controller.error?.contains("Try Again") == true)
    }

    func testModelChangePreparesTheChosenModelBeforeAllowingAnotherRecording() async {
        let engine = ControlledDictationEngine()
        let recorder = ControlledDictationRecorder()
        let controller = makeController(engine: engine, recorder: recorder)
        controller.restore()
        await controller.operation?.value
        XCTAssertEqual(engine.loadedModel, .turbo)
        engine.blockNextPreparation = true
        controller.selectModel(.small)
        await engine.waitForPreparation()
        XCTAssertEqual(controller.model, .small)
        XCTAssertEqual(controller.phase, .preparing)
        controller.shortcutPressed()
        XCTAssertEqual(recorder.starts, 0)
        engine.finishPreparation()
        await controller.operation?.value
        XCTAssertEqual(engine.loadedModel, .small)
        XCTAssertEqual(engine.models, [.turbo, .small])
        XCTAssertEqual(controller.phase, .ready)
    }

    func testModelChangeDuringDownloadCancelsAndRestartsWithTheNewChoice() async {
        for model in [DictationModel.small, .largeV3, .qwen3ASR] {
            let engine = ControlledDictationEngine()
            engine.blockNextPreparation = true
            let controller = makeController(engine: engine, recorder: ControlledDictationRecorder())
            controller.restore()
            await engine.waitForPreparation()
            let previous = controller.operation
            controller.selectModel(model)
            XCTAssertEqual(controller.phase, .cancelling)
            engine.finishPreparation()
            await previous?.value
            await controller.operation?.value
            XCTAssertEqual(engine.models, [.turbo, model])
            XCTAssertEqual(engine.loadedModel, model)
            XCTAssertEqual(controller.phase, .ready)
        }
    }

    func testModelChoicePersistsWhileDisabledWithoutPreparingOrRequestingTheMicrophone() async {
        let engine = ControlledDictationEngine()
        let recorder = ControlledDictationRecorder()
        var saved: [DictationModel] = []
        let controller = DictationController(enabled: false, engine: engine, recorder: recorder,
            interaction: DictationInteraction(endCapture: {},
                                              showError: { _ in }, showResult: { _ in }),
            saveModel: { saved.append($0) })
        XCTAssertEqual(controller.model, .turbo)
        for model in DictationModel.allCases {
            controller.selectModel(model)
            controller.selectModel(model)
            XCTAssertEqual(controller.model, model)
        }
        XCTAssertEqual(saved, DictationModel.allCases)
        XCTAssertNil(controller.operation)
        XCTAssertTrue(engine.models.isEmpty)
        XCTAssertEqual(recorder.permissions, 0)
    }

    func testRecordingRejectsModelChanges() async {
        let engine = ControlledDictationEngine()
        let recorder = ControlledDictationRecorder()
        let controller = makeController(engine: engine, recorder: recorder)
        controller.restore()
        await controller.operation?.value
        controller.shortcutPressed()
        XCTAssertEqual(recorder.starts, 1)
        for model in DictationModel.allCases {
            controller.selectModel(model)
            XCTAssertEqual(controller.model, .turbo)
        }
        XCTAssertEqual(engine.models, [.turbo])
        controller.cancel()
    }

    func testMicrophoneStartupFailureReportsTheCauseAndReleasesCapture() async {
        let engine = ControlledDictationEngine()
        let recorder = ControlledDictationRecorder()
        let controller = makeController(engine: engine, recorder: recorder)
        controller.restore()
        await controller.operation?.value
        recorder.startError = .microphone
        controller.shortcutPressed()
        XCTAssertEqual(recorder.starts, 1)
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(controller.error, DictationError.microphone.localizedDescription)
        XCTAssertFalse(recorder.hasAudio)
        XCTAssertFalse(TranslationActivity.shared.isBusy)
        XCTAssertTrue(engine.transcribed.isEmpty)
    }

    func testInterruptedAudioNeverRecognizesPartialRecording() async {
        let engine = ControlledDictationEngine()
        let recorder = ControlledDictationRecorder()
        let controller = makeController(engine: engine, recorder: recorder)
        controller.restore()
        await controller.operation?.value
        controller.shortcutPressed()
        XCTAssertTrue(recorder.hasAudio)
        recorder.onEnd?(false)
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertFalse(recorder.hasAudio)
        XCTAssertFalse(TranslationActivity.shared.isBusy)
        XCTAssertTrue(engine.transcribed.isEmpty)
    }

    private func makeController(engine: ControlledDictationEngine,
                                recorder: ControlledDictationRecorder) -> DictationController {
        DictationController(enabled: true, engine: engine, recorder: recorder,
                            interaction: DictationInteraction(endCapture: {}, showError: { _ in },
                                                              showResult: { _ in }), saveModel: { _ in })
    }
}

// Input preparation between holds (raw prepared capture).
extension DictationControllerTests {
    func testInputIsPreparedOnlyAfterMicrophoneAccessIsGranted() async {
        let engine = ControlledDictationEngine()
        let denied = ControlledDictationRecorder()
        denied.permitted = false
        let refused = makeController(engine: engine, recorder: denied)
        refused.restore()
        await refused.operation?.value
        XCTAssertEqual(denied.permissions, 1)
        XCTAssertTrue(denied.warmUps.isEmpty)

        let recorder = ControlledDictationRecorder()
        let controller = makeController(engine: engine, recorder: recorder)
        controller.restore()
        await controller.operation?.value
        XCTAssertEqual(recorder.warmUps, [false])
        controller.systemDidWake()
        XCTAssertEqual(recorder.warmUps, [false, true])
    }

    func testWakeDoesNotPrepareInputWhileDisabled() {
        let recorder = ControlledDictationRecorder()
        let controller = DictationController(enabled: false, engine: ControlledDictationEngine(), recorder: recorder,
            interaction: DictationInteraction(endCapture: {},
                                              showError: { _ in }, showResult: { _ in }),
            saveModel: { _ in })
        controller.systemDidWake()
        XCTAssertTrue(recorder.warmUps.isEmpty)
    }
}

@MainActor
private final class ControlledDictationEngine: DictationRecognizing {
    var loaded = false
    var transcript = ""
    var blockNextPreparation = false
    var failNextPreparation = false
    var preparations: [Bool] = []
    var models: [DictationModel] = []
    private(set) var loadedModel: DictationModel?
    var transcribed: [URL] = []
    private var pending: CheckedContinuation<Void, Never>?
    private var preparationObserver: CheckedContinuation<Void, Never>?
    private var unloadObserver: CheckedContinuation<Void, Never>?
    private var unloaded = false

    func prepare(model: DictationModel, download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        loaded = false
        preparations.append(download)
        models.append(model)
        if blockNextPreparation {
            blockNextPreparation = false
            await withCheckedContinuation { pending = $0
                preparationObserver?.resume()
                preparationObserver = nil
            }
        }
        try Task.checkCancellation()
        if failNextPreparation {
            failNextPreparation = false
            throw DictationError.notReady
        }
        loaded = true
        loadedModel = model
    }

    func transcribe(_ audio: URL) async throws -> String {
        XCTAssertTrue(loaded)
        transcribed.append(audio)
        return transcript
    }

    func unload() async {
        loaded = false
        loadedModel = nil
        unloaded = true
        unloadObserver?.resume()
        unloadObserver = nil
    }

    func waitForUnload() async {
        if !unloaded { await withCheckedContinuation { unloadObserver = $0 } }
    }

    func waitForPreparation() async {
        if pending == nil { await withCheckedContinuation { preparationObserver = $0 } }
    }

    func finishPreparation() {
        pending?.resume()
        pending = nil
    }
}

@MainActor
private final class ControlledDictationRecorder: DictationRecording {
    var onEnd: ((Bool) -> Void)?
    let level = 0.5
    let isDeliveringAudio = true
    let audio = URL(fileURLWithPath: "/synthetic-dictation.wav")
    var permissions = 0
    var permitted = true
    var warmUps: [Bool] = []
    var starts = 0
    var stops = 0
    var hasAudio = false
    var startError: DictationError?
    var blockDrain = false
    private var drain: CheckedContinuation<URL, Error>?
    private var drainObserver: CheckedContinuation<Void, Never>?

    func requestPermission() async -> Bool { permissions += 1; return permitted }
    func warmUp(rebuild: Bool) { warmUps.append(rebuild) }
    func coolDown() {}
    func start() throws {
        starts += 1
        hasAudio = true
        if let startError { throw startError }
    }
    func stop() throws -> Task<URL, Error> {
        stops += 1
        return Task {
            if blockDrain {
                return try await withCheckedThrowingContinuation { continuation in
                    drain = continuation
                    drainObserver?.resume()
                    drainObserver = nil
                }
            }
            return audio
        }
    }
    func waitForDrain() async {
        if drain == nil { await withCheckedContinuation { drainObserver = $0 } }
    }
    func finishDrain() { drain?.resume(returning: audio); drain = nil }
    func discard() { hasAudio = false }
    func shutdown() { discard() }
}

import Foundation
import XCTest
@testable import TranslateLikeMe

@MainActor
final class DictationControllerTests: XCTestCase {
    func testMicrophoneStartsBeforeReadingTheInsertionTarget() async {
        let engine = ControlledDictationEngine()
        let recorder = ControlledDictationRecorder()
        var inspectedTarget = false
        let controller = DictationController(enabled: true, engine: engine, recorder: recorder,
            interaction: DictationInteraction(beginCapture: { _ in
                inspectedTarget = true
                XCTAssertEqual(recorder.starts, 1, "Accessibility must not delay microphone startup")
                XCTAssertTrue(recorder.hasAudio)
                return (nil, {})
            }, endCapture: {}, showError: { _ in }, showResult: { _ in }), saveModel: { _ in })
        controller.restore()
        await controller.operation?.value
        defer { controller.cancel() }

        controller.shortcutPressed()

        XCTAssertTrue(inspectedTarget, "The real capture path must inspect the insertion target")
        XCTAssertEqual(recorder.starts, 1)
        XCTAssertTrue(controller.isActive)
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
        controller.cancel(restartPreparation: false)
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
        let engine = ControlledDictationEngine()
        engine.blockNextPreparation = true
        let controller = makeController(engine: engine, recorder: ControlledDictationRecorder())
        controller.restore()
        await engine.waitForPreparation()
        let previous = controller.operation
        controller.selectModel(.largeV3)
        XCTAssertEqual(controller.phase, .cancelling)
        engine.finishPreparation()
        await previous?.value
        await controller.operation?.value
        XCTAssertEqual(engine.models, [.turbo, .largeV3])
        XCTAssertEqual(engine.loadedModel, .largeV3)
        XCTAssertEqual(controller.phase, .ready)
    }

    func testModelChoicePersistsWhileDisabledWithoutPreparingOrRequestingTheMicrophone() async {
        let engine = ControlledDictationEngine()
        let recorder = ControlledDictationRecorder()
        var saved: [DictationModel] = []
        let controller = DictationController(enabled: false, engine: engine, recorder: recorder,
            interaction: DictationInteraction(beginCapture: { _ in (nil, {}) }, endCapture: {},
                                              showError: { _ in }, showResult: { _ in }),
            saveModel: { saved.append($0) })
        controller.selectModel(.small)
        controller.selectModel(.small)
        XCTAssertEqual(controller.model, .small)
        XCTAssertEqual(saved, [.small])
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
        controller.selectModel(.small)
        XCTAssertEqual(controller.model, .turbo)
        XCTAssertEqual(engine.models, [.turbo])
        controller.cancel()
    }

    func testUnavailableEchoCancellationReportsTheCauseAndReleasesCapture() async {
        let engine = ControlledDictationEngine()
        let recorder = ControlledDictationRecorder()
        let controller = makeController(engine: engine, recorder: recorder)
        controller.restore()
        await controller.operation?.value
        recorder.startError = .voiceProcessing
        controller.shortcutPressed()
        XCTAssertEqual(recorder.starts, 1)
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(controller.error, DictationError.voiceProcessing.localizedDescription)
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
                            interaction: DictationInteraction(beginCapture: { _ in (nil, {}) },
                                                              endCapture: {}, showError: { _ in },
                                                              showResult: { _ in }), saveModel: { _ in })
    }
}

@MainActor
private final class ControlledDictationEngine: DictationRecognizing {
    var loaded = false
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
        return ""
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
    var starts = 0
    var stops = 0
    var hasAudio = false
    var startError: DictationError?

    func requestPermission() async -> Bool { permissions += 1; return true }
    func start() throws {
        starts += 1
        hasAudio = true
        if let startError { throw startError }
    }
    func stop() throws -> URL { stops += 1; return audio }
    func discard() { hasAudio = false }
}

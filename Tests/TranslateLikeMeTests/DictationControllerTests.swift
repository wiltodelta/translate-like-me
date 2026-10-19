import Foundation
import XCTest
@testable import TranslateLikeMe

@MainActor
final class DictationControllerTests: XCTestCase {
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

    private func makeController(engine: ControlledDictationEngine,
                                recorder: ControlledDictationRecorder) -> DictationController {
        DictationController(enabled: true, engine: engine, recorder: recorder,
                            interaction: DictationInteraction(beginCapture: { _ in (nil, {}) },
                                                              endCapture: {}, showError: { _ in },
                                                              showResult: { _ in }))
    }
}

@MainActor
private final class ControlledDictationEngine: DictationRecognizing {
    var loaded = false
    var blockNextPreparation = false
    var failNextPreparation = false
    var preparations: [Bool] = []
    var transcribed: [URL] = []
    private var pending: CheckedContinuation<Void, Never>?
    private var preparationObserver: CheckedContinuation<Void, Never>?
    private var unloadObserver: CheckedContinuation<Void, Never>?
    private var unloaded = false

    func prepare(download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !loaded else { return }
        preparations.append(download)
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
    }

    func transcribe(_ audio: URL) async throws -> String {
        XCTAssertTrue(loaded)
        transcribed.append(audio)
        return ""
    }

    func unload() async {
        loaded = false
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
    var starts = 0
    var stops = 0
    var hasAudio = false

    func requestPermission() async -> Bool { true }
    func start() throws { starts += 1; hasAudio = true }
    func stop() throws -> URL { stops += 1; return audio }
    func discard() { hasAudio = false }
}

import XCTest
@testable import TranslateLikeMe

// Recording continues briefly after release so a last word is not cut off.
@MainActor
final class DictationReleaseTailTests: XCTestCase {
    private let entered = TestGate()
    private let elapsed = TestGate()

    func testReleaseKeepsRecordingThroughTheTailBeforeStopping() async {
        let engine = ControlledDictationEngine()
        let recorder = ControlledDictationRecorder()
        let controller = await holdAndRelease(engine: engine, recorder: recorder)
        XCTAssertEqual(recorder.stops, 0, "Release must keep recording through the tail")
        guard recorder.stops == 0 else { return await controller.operation?.value ?? () }
        await entered.wait()
        XCTAssertTrue(recorder.hasAudio)
        let tail = controller.tail
        await elapsed.open()
        await tail?.value
        XCTAssertEqual(recorder.stops, 1)
        await controller.operation?.value
        XCTAssertEqual(engine.transcribed, [recorder.audio])
        XCTAssertEqual(controller.phase, .ready)
    }

    func testCancellationDuringTheTailNeverRecognizes() async {
        let engine = ControlledDictationEngine()
        let recorder = ControlledDictationRecorder()
        let controller = await holdAndRelease(engine: engine, recorder: recorder)
        await entered.wait()
        let tail = controller.tail
        XCTAssertNotNil(tail)
        controller.cancel()
        XCTAssertFalse(recorder.hasAudio)
        await elapsed.open()
        await tail?.value
        XCTAssertEqual(recorder.stops, 0)
        XCTAssertTrue(engine.transcribed.isEmpty)
        XCTAssertEqual(controller.phase, .ready)
    }

    func testQuietAfterReleaseEndsTheTailEarly() async {
        let recorder = ControlledDictationRecorder()
        recorder.trailingQuiet = 0.4
        let (controller, sleeps) = await releaseWithCountedSleeps(recorder: recorder)
        await controller.tail?.value
        XCTAssertEqual(sleeps.count, 4, "Quiet audio stops 200 ms after release")
        XCTAssertEqual(recorder.stops, 1)
        await controller.operation?.value
    }

    func testSpeechOrAnUnreadableRoomKeepsTheFullTail() async {
        for quiet in [0, 0.2] as [TimeInterval] {
            let recorder = ControlledDictationRecorder()
            recorder.trailingQuiet = quiet
            let (controller, sleeps) = await releaseWithCountedSleeps(recorder: recorder)
            await controller.tail?.value
            XCTAssertEqual(sleeps.count, 14, "A last word still being spoken keeps the whole 700 ms")
            XCTAssertEqual(recorder.stops, 1)
            await controller.operation?.value
        }
    }

    private final class Sleeps { var count = 0 }

    private func releaseWithCountedSleeps(
        recorder: ControlledDictationRecorder) async -> (DictationController, Sleeps) {
        let sleeps = Sleeps()
        let controller = DictationController(enabled: true, engine: ControlledDictationEngine(), recorder: recorder,
            interaction: DictationInteraction(endCapture: {}, showError: { _ in }, showResult: { _ in }),
            releaseTail: .milliseconds(700), sleep: { _ in sleeps.count += 1 }, saveModel: { _ in })
        controller.restore()
        await controller.operation?.value
        controller.shortcutPressed()
        controller.shortcutReleased()
        XCTAssertEqual(recorder.stops, 0)
        return (controller, sleeps)
    }

    private func holdAndRelease(engine: ControlledDictationEngine,
                                recorder: ControlledDictationRecorder) async -> DictationController {
        let controller = DictationController(enabled: true, engine: engine, recorder: recorder,
            interaction: DictationInteraction(endCapture: {}, showError: { _ in }, showResult: { _ in }),
            releaseTail: .milliseconds(700), sleep: { [entered, elapsed] delay in
                XCTAssertEqual(delay, .milliseconds(50))
                await entered.open()
                await elapsed.wait()
            }, saveModel: { _ in })
        controller.restore()
        await controller.operation?.value
        controller.shortcutPressed()
        controller.shortcutReleased()
        return controller
    }
}

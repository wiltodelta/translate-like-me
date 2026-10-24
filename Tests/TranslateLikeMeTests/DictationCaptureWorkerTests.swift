import AVFoundation
import CoreAudio
import Foundation
import XCTest
@testable import TranslateLikeMe

final class DictationCaptureWorkerTests: XCTestCase {
    func testStartupFormatChangeRebuildsTheGraphAndRecordsAtTheNewRate() async throws {
        let done = expectation(description: "Startup recovered or failed")
        let scenario = CaptureGraphScenario(changes: 1, completed: { done.fulfill() })
        let worker = makeWorker(scenario)
        let request = DictationCaptureRequest()
        defer { worker.shutdown() }
        worker.prepare(rebuild: false)
        worker.start(request) { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        request.end()
        do {
            let url = try await worker.stop(request).value
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
            XCTAssertEqual(file.length, 160)
        } catch { XCTFail("Startup format change must recover: \(error)") }
        XCTAssertEqual(scenario.graphs, 2)
        worker.discard(request)
        worker.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.url.path))
    }

    func testSilentStartupBufferDoesNotBlockFormatRecovery() async throws {
        let done = expectation(description: "Silent startup recovered or failed")
        let scenario = CaptureGraphScenario(changes: 1, startupSample: 0, completed: { done.fulfill() })
        let worker = makeWorker(scenario)
        let request = DictationCaptureRequest()
        defer { worker.shutdown() }
        worker.start(request) { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        request.end()
        do {
            let url = try await worker.stop(request).value
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
            XCTAssertEqual(file.length, 160, "Discard only the old generation's startup silence")
        } catch { XCTFail("Initial zeros must not prevent format recovery: \(error)") }
        XCTAssertEqual(scenario.graphs, 2)
    }

    func testFormatChangeAfterAudioRejectsThePartialRecording() async {
        let done = expectation(description: "Interrupted recording failed")
        let scenario = CaptureGraphScenario(changes: 1, startupSample: 0.25, completed: {})
        let worker = makeWorker(scenario)
        let request = DictationCaptureRequest()
        defer { worker.shutdown() }
        worker.start(request) { success in
            XCTAssertFalse(success)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertTrue(request.sink?.isDeliveringAudio == true)
        XCTAssertNotNil(request.failure)
        XCTAssertEqual(scenario.graphs, 1)
        worker.discard(request)
        worker.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.url.path))
    }

    func testStableMutedStreamDoesNotTriggerRebuildOrFailure() async throws {
        let done = expectation(description: "Silent stream delivered")
        let scenario = CaptureGraphScenario(changes: 0, finalSample: 0, completed: { done.fulfill() })
        let worker = makeWorker(scenario)
        let request = DictationCaptureRequest()
        defer { worker.shutdown() }
        worker.start(request) { _ in XCTFail("An uninterrupted silent stream is not a capture failure") }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertTrue(request.sink?.isDeliveringAudio == true)
        XCTAssertTrue(request.sink?.hasSignal == false)
        XCTAssertNil(request.failure)
        request.end()
        let url = try await worker.stop(request).value
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 160)
        XCTAssertEqual(scenario.graphs, 1)
    }

    func testRepeatedStartupChangesHaveABoundedRetryBudget() async {
        let done = expectation(description: "Unstable input failed")
        let scenario = CaptureGraphScenario(changes: 10, completed: {})
        let worker = makeWorker(scenario)
        let request = DictationCaptureRequest()
        defer { worker.shutdown() }
        worker.start(request) { success in
            XCTAssertFalse(success)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNotNil(request.failure)
        XCTAssertEqual(scenario.graphs, 3)
    }

    func testReleaseBeforeConfigurationCallbackNeverRestartsTheMicrophone() async {
        let queued = expectation(description: "Configuration callback queued after release")
        let request = DictationCaptureRequest()
        let scenario = CaptureGraphScenario(changes: 1, beforeChange: { request.end() },
                                            afterChange: { queued.fulfill() }, completed: {})
        let worker = makeWorker(scenario)
        worker.start(request) { _ in }
        await fulfillment(of: [queued], timeout: 2)
        worker.shutdown()
        XCTAssertFalse(request.isActive)
        XCTAssertEqual(scenario.graphs, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.url.path))
    }

    private func makeWorker(_ scenario: CaptureGraphScenario) -> DictationCaptureWorker {
        DictationCaptureWorker(mute: DictationOutputMute(control: UnavailableCaptureOutput()),
            playback: DictationMediaPlayback(command: { _, _ in "{\"status\":\"ignored\"}" }),
            resolveInput: { _ in DictationInputRoute(device: 77, uid: "test-input") },
            observeInputs: { _ in RouteTestObservation() },
            makeGraph: { _, _, relay, changed in scenario.makeGraph(relay: relay, changed: changed) })
    }
}

// Only counters cross the worker queue. The graph itself stays on that queue.
private final class CaptureGraphScenario: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var firstRelay: DictationTapRelay?
    private let changes: Int
    private let startupSample: Float?
    private let finalSample: Float
    private let beforeChange: @Sendable () -> Void
    private let afterChange: @Sendable () -> Void
    private let completed: @Sendable () -> Void
    var graphs: Int { lock.withLock { count } }

    init(changes: Int, startupSample: Float? = nil, finalSample: Float = 0.25,
         beforeChange: @escaping @Sendable () -> Void = {},
         afterChange: @escaping @Sendable () -> Void = {}, completed: @escaping @Sendable () -> Void) {
        self.changes = changes
        self.startupSample = startupSample
        self.finalSample = finalSample
        self.beforeChange = beforeChange
        self.afterChange = afterChange
        self.completed = completed
    }

    func makeGraph(relay: DictationTapRelay, changed: @escaping @Sendable () -> Void) -> any DictationInputGraph {
        let index = lock.withLock { let index = count; count += 1; return index }
        if index == 0 { firstRelay = relay }
        return SyntheticCaptureGraph(rate: index == 0 ? 44_100 : 16_000, start: { graph in
            if index < self.changes {
                if let sample = self.startupSample { try graph.deliver(to: relay, sample: sample) }
                self.beforeChange()
                graph.format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                graph.isRunning = false
                changed()
                self.afterChange()
            } else {
                try graph.deliver(to: relay, sample: self.finalSample)
                // A queued callback from the old tap must not append to the new WAV.
                if index > 0, let firstRelay = self.firstRelay { try graph.deliver(to: firstRelay) }
                self.completed()
            }
        })
    }
}

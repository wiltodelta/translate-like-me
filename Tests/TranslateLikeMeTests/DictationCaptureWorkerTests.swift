import AVFoundation
import CoreAudio
import Foundation
import Synchronization
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

    // AirPods failed start() with -10868 on an idle graph built for their previous format (2026-10-25).
    func testFailedStartBeforeAudioRebuildsTheGraph() async throws {
        let done = expectation(description: "Failed start recovered")
        let scenario = CaptureGraphScenario(changes: 0, failedStarts: 1, completed: { done.fulfill() })
        let worker = makeWorker(scenario)
        let request = DictationCaptureRequest()
        defer { worker.shutdown() }
        worker.prepare(rebuild: false)
        worker.start(request) { _ in XCTFail("A recovered start must not end the hold") }
        await fulfillment(of: [done], timeout: 2)
        request.end()
        let url = try await worker.stop(request).value
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 160)
        XCTAssertEqual(scenario.graphs, 2)
    }

    func testRunningGraphWithoutBuffersIsRebuilt() async throws {
        let done = expectation(description: "Silent graph replaced")
        let scenario = CaptureGraphScenario(changes: 0, deadStarts: 1, completed: { done.fulfill() })
        let worker = makeWorker(scenario, firstBufferLimit: .milliseconds(20))
        let request = DictationCaptureRequest()
        defer { worker.shutdown() }
        worker.start(request) { _ in XCTFail("A recovered start must not end the hold") }
        await fulfillment(of: [done], timeout: 2)
        request.end()
        let url = try await worker.stop(request).value
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 160)
        XCTAssertEqual(scenario.graphs, 2)
    }

    func testRepeatedFailedStartsHaveABoundedRetryBudget() async {
        let done = expectation(description: "Unstartable input failed")
        let scenario = CaptureGraphScenario(changes: 0, failedStarts: 10, completed: {})
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

    // Building an AirPods graph moved the input's nominal rate between 24 and 48 kHz, and
    // a pre-build snapshot rebuilt the idle graph about four times a second (2026-10-25).
    func testRateMovedByBuildingTheGraphDoesNotRebuildItAgain() async {
        let observing = expectation(description: "Input observer registered")
        let rate = Mutex(24_000.0)
        let notify = Mutex<(@Sendable () -> Void)?>(nil)
        let scenario = CaptureGraphScenario(changes: 0, building: { _ in
            rate.withLock { $0 = $0 == 24_000 ? 48_000 : 24_000 }
        }, completed: {})
        let worker = makeWorker(scenario, resolveInput: { _ in
            DictationInputRoute(device: 77, uid: "test-input", sampleRate: rate.withLock { $0 })
        }, observeInputs: { changed in
            notify.withLock { $0 = changed }
            observing.fulfill()
            return RouteTestObservation()
        })
        defer { worker.shutdown() }
        await fulfillment(of: [observing], timeout: 2)
        worker.prepare(rebuild: false)
        for _ in 0..<3 { notify.withLock { $0 }?() }
        worker.shutdown()
        XCTAssertEqual(scenario.graphs, 1)
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

    private func makeWorker(_ scenario: CaptureGraphScenario,
                            resolveInput: @escaping @Sendable (String?) -> DictationInputRoute? = { _ in
                                DictationInputRoute(device: 77, uid: "test-input")
                            },
                            observeInputs: @escaping DictationCaptureWorker.ObserveInputs = { _ in
                                RouteTestObservation()
                            },
                            firstBufferLimit: DispatchTimeInterval = .seconds(60)) -> DictationCaptureWorker {
        DictationCaptureWorker(mute: DictationOutputMute(control: UnavailableCaptureOutput()),
            resolveInput: resolveInput, observeInputs: observeInputs, firstBufferLimit: firstBufferLimit,
            makeGraph: { _, _, relay, changed in scenario.makeGraph(relay: relay, changed: changed) })
    }
}

// Only counters cross the worker queue. The graph itself stays on that queue.
private final class CaptureGraphScenario: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var firstRelay: DictationTapRelay?
    private let changes: Int
    private let failedStarts: Int
    private let deadStarts: Int
    private let startupSample: Float?
    private let finalSample: Float
    private let beforeChange: @Sendable () -> Void
    private let afterChange: @Sendable () -> Void
    private let building: @Sendable (Int) -> Void
    private let completed: @Sendable () -> Void
    var graphs: Int { lock.withLock { count } }

    init(changes: Int, failedStarts: Int = 0, deadStarts: Int = 0, startupSample: Float? = nil,
         finalSample: Float = 0.25,
         beforeChange: @escaping @Sendable () -> Void = {},
         afterChange: @escaping @Sendable () -> Void = {},
         building: @escaping @Sendable (Int) -> Void = { _ in }, completed: @escaping @Sendable () -> Void) {
        self.changes = changes
        self.failedStarts = failedStarts
        self.deadStarts = deadStarts
        self.startupSample = startupSample
        self.finalSample = finalSample
        self.beforeChange = beforeChange
        self.afterChange = afterChange
        self.building = building
        self.completed = completed
    }

    func makeGraph(relay: DictationTapRelay, changed: @escaping @Sendable () -> Void) -> any DictationInputGraph {
        let index = lock.withLock { let index = count; count += 1; return index }
        if index == 0 { firstRelay = relay }
        building(index)
        return SyntheticCaptureGraph(rate: index == 0 ? 44_100 : 16_000, start: { graph in
            if index < self.failedStarts {
                graph.isRunning = false
                throw NSError(domain: "com.apple.coreaudio.avfaudio", code: -10_868)
            } else if index < self.deadStarts {
                return
            } else if index < self.changes {
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

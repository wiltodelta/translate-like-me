import AVFoundation
import CoreAudio
import XCTest
@testable import TranslateLikeMe

final class DictationInputRouteTests: XCTestCase {
    func testSameFormatDeviceSwitchAfterSpeechRejectsPartialAudio() async {
        let started = expectation(description: "Audio delivered")
        let scenario = RouteScenario(started: { _ in started.fulfill() })
        let worker = scenario.worker()
        let request = DictationCaptureRequest()
        worker.start(request) { _ in }
        await fulfillment(of: [started], timeout: 2)
        scenario.change(to: DictationInputRoute(device: 90, uid: "usb"))
        worker.shutdown() // Drains the queued route event before checking the result.
        XCTAssertNotNil(request.failure, "A same-format route change must not accept a partial recording")
        XCTAssertEqual(scenario.graphCount, 1)
        XCTAssertTrue(scenario.observationStopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.url.path))
    }

    func testIdleRouteChangeRebuildsWithoutStartingTheMicrophone() async {
        let created = expectation(description: "Idle graph prepared")
        let scenario = RouteScenario(created: { index in if index == 1 { created.fulfill() } })
        let worker = scenario.worker()
        worker.prepare(rebuild: false)
        await fulfillment(of: [created], timeout: 2)
        scenario.change(to: DictationInputRoute(device: 90, uid: "usb"))
        worker.shutdown()
        XCTAssertEqual(scenario.graphCount, 2)
        XCTAssertEqual(scenario.startCount, 0)
    }

    func testReusedNumericDeviceIDIsDetectedOnTheNextPressWithoutAnEvent() async throws {
        let started = expectation(description: "Two holds started")
        started.expectedFulfillmentCount = 2
        let scenario = RouteScenario(started: { _ in started.fulfill() })
        let worker = scenario.worker()
        defer { worker.shutdown() }
        worker.prepare(rebuild: false)
        let first = DictationCaptureRequest()
        worker.start(first) { _ in }
        // Stop is queued after start, so no wall-clock delay is needed.
        _ = try await worker.stop(first).value
        worker.discard(first)
        scenario.change(to: DictationInputRoute(device: 77, uid: "different-device"), notify: false)
        let second = DictationCaptureRequest()
        worker.start(second) { _ in }
        await fulfillment(of: [started], timeout: 2)
        worker.shutdown()
        XCTAssertEqual(scenario.graphCount, 2, "Device ID equality is not device identity")
    }

    func testExplicitSelectionIsPinnedEvenWhenItMatchesTheSystemInput() async {
        for preferred in [nil, "built-in", "disconnected-usb"] {
            let started = expectation(description: "Selected input started")
            let scenario = RouteScenario(started: { _ in started.fulfill() })
            let worker = scenario.worker()
            worker.useInput(preferred)
            let request = DictationCaptureRequest()
            worker.start(request) { _ in }
            await fulfillment(of: [started], timeout: 2)
            worker.shutdown()
            XCTAssertEqual(scenario.bindingPolicies, [preferred != "built-in"])
        }
    }

    func testStartupRouteSwitchDiscardsOnlySilenceAndUsesTheNewNativeFormat() async throws {
        let initial = expectation(description: "Startup silence delivered")
        let recovered = expectation(description: "Replacement input delivered")
        let scenario = RouteScenario(firstSample: 0, started: { count in
            if count == 1 { initial.fulfill() } else { recovered.fulfill() }
        })
        let worker = scenario.worker()
        defer { worker.shutdown() }
        let request = DictationCaptureRequest()
        worker.start(request) { _ in XCTFail("A silent startup route switch must recover") }
        await fulfillment(of: [initial], timeout: 2)
        scenario.change(to: DictationInputRoute(device: 90, uid: "bluetooth-hfp", sampleRate: 16_000))
        await fulfillment(of: [recovered], timeout: 2)
        request.end()
        let url = try await worker.stop(request).value
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.length, 160)
        XCTAssertEqual(scenario.graphCount, 2)
    }

    func testDisconnectionAfterSpeechFailsInsteadOfSwitchingMidRecording() async {
        let started = expectation(description: "Input delivered")
        let scenario = RouteScenario(started: { _ in started.fulfill() })
        let worker = scenario.worker()
        let request = DictationCaptureRequest()
        worker.start(request) { _ in }
        await fulfillment(of: [started], timeout: 2)
        scenario.change(to: nil)
        worker.shutdown()
        XCTAssertNotNil(request.failure)
        XCTAssertEqual(scenario.startCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.url.path))
    }

    func testNativeRateAndChannelMatrixThroughTheActualCaptureFileAndLoader() async throws {
        for rate in [8_000.0, 16_000, 24_000, 44_100, 48_000, 96_000, 192_000] {
            for channels: UInt32 in [1, 2, 3, 8] {
                let started = expectation(description: "Native input delivered")
                let route = DictationInputRoute(device: 90, uid: "test-input", channels: channels, sampleRate: rate)
                let scenario = RouteScenario(route: route, started: { _ in started.fulfill() })
                let worker = scenario.worker()
                defer { worker.shutdown() }
                let request = DictationCaptureRequest()
                worker.start(request) { _ in XCTFail("Valid native input failed") }
                await fulfillment(of: [started], timeout: 2)
                request.end()
                let url = try await worker.stop(request).value
                let file = try AVAudioFile(forReading: url)
                XCTAssertEqual(file.processingFormat.sampleRate, rate)
                XCTAssertEqual(file.processingFormat.channelCount, channels)
                XCTAssertEqual(file.length, 160)
                let samples = try DictationAudioLoader.load(url)
                XCTAssertLessThanOrEqual(abs(Double(samples.count) - 160 * 16_000 / rate), 1)
                XCTAssertTrue(samples.allSatisfy(\.isFinite))
                worker.shutdown()
                XCTAssertFalse(FileManager.default.fileExists(atPath: request.url.path))
            }
        }
    }

    func testMissingIdleInputPreparesWhenADeviceReturns() async {
        let missing = expectation(description: "No usable input observed")
        let scenario = RouteScenario(route: nil, resolved: { route in if route == nil { missing.fulfill() } })
        let worker = scenario.worker()
        worker.prepare(rebuild: false)
        await fulfillment(of: [missing], timeout: 2)
        scenario.change(to: DictationInputRoute(device: 90, uid: "usb"))
        worker.shutdown()
        XCTAssertEqual(scenario.graphCount, 1)
        XCTAssertEqual(scenario.startCount, 0)
    }

    func testNativePropertiesChangingBeforeEngineNotificationInvalidateActiveCapture() async {
        let original = DictationInputRoute(device: 77, uid: "built-in", sampleRate: 48_000)
        var rate = original
        rate.sampleRate = 96_000
        var channels = original
        channels.channels = 2
        var source = original
        source.dataSource = 42
        for replacement in [rate, channels, source] {
            let started = expectation(description: "Native capture delivered")
            let scenario = RouteScenario(route: original, started: { _ in started.fulfill() })
            let worker = scenario.worker()
            let request = DictationCaptureRequest()
            worker.start(request) { _ in }
            await fulfillment(of: [started], timeout: 2)
            scenario.change(to: replacement)
            worker.shutdown()
            XCTAssertNotNil(request.failure)
            XCTAssertEqual(scenario.startCount, 1)
        }
    }

    func testQueuedInputNotificationAfterShutdownCannotReopenTheMicrophone() async {
        let created = expectation(description: "Prepared graph")
        let scenario = RouteScenario(created: { _ in created.fulfill() })
        let worker = scenario.worker()
        worker.prepare(rebuild: false)
        await fulfillment(of: [created], timeout: 2)
        let queued = scenario.inputCallback
        worker.shutdown()
        scenario.change(to: DictationInputRoute(device: 90, uid: "usb"), notify: false)
        queued?()
        worker.shutdown() // Drain the callback that was already in flight when HAL unregistered it.
        XCTAssertEqual(scenario.graphCount, 1)
        XCTAssertEqual(scenario.startCount, 0)
        XCTAssertTrue(scenario.observationStopped)
    }

    func testRepeatedUnrelatedNotificationsDoNotRebuildAPreparedInput() async {
        let created = expectation(description: "Prepared graph")
        let scenario = RouteScenario(created: { _ in created.fulfill() })
        let worker = scenario.worker()
        worker.prepare(rebuild: false)
        await fulfillment(of: [created], timeout: 2)
        for _ in 0..<100 { scenario.change(to: DictationInputRoute(device: 77, uid: "built-in")) }
        worker.shutdown()
        XCTAssertEqual(scenario.graphCount, 1)
        XCTAssertEqual(scenario.startCount, 0)
    }

    func testStoppedEngineOrUnreportedRouteChangeIsRejectedAtDrain() async {
        for stopped in [true, false] {
            let started = expectation(description: "Capture delivered")
            let scenario = RouteScenario(stopAfterDelivery: stopped, started: { _ in started.fulfill() })
            let worker = scenario.worker()
            defer { worker.shutdown() }
            let request = DictationCaptureRequest()
            worker.start(request) { _ in }
            await fulfillment(of: [started], timeout: 2)
            if !stopped { scenario.change(to: DictationInputRoute(device: 90, uid: "usb"), notify: false) }
            request.end()
            do {
                _ = try await worker.stop(request).value
                XCTFail("Drain must recheck hardware state even when the notification has not arrived")
            } catch {
                XCTAssertNotNil(request.failure)
            }
        }
    }

    func testUnrelatedDeviceListEventKeepsThePreparedGraph() async {
        let created = expectation(description: "Prepared")
        let scenario = RouteScenario(created: { index in if index == 1 { created.fulfill() } })
        let worker = scenario.worker()
        worker.prepare(rebuild: false)
        await fulfillment(of: [created], timeout: 2)
        scenario.change(to: DictationInputRoute(device: 77, uid: "built-in"))
        worker.shutdown()
        XCTAssertEqual(scenario.graphCount, 1, "Private engine aggregates must not cause rebuild loops")
        XCTAssertEqual(scenario.startCount, 0)
    }
}

private final class RouteScenario: @unchecked Sendable {
    private let lock = NSLock()
    private var route: DictationInputRoute? = DictationInputRoute(device: 77, uid: "built-in")
    private var changed: (@Sendable () -> Void)?
    private var graphs = 0
    private var starts = 0
    private var stopped = false
    private let created: @Sendable (Int) -> Void
    private let started: @Sendable (Int) -> Void
    private let firstSample: Float
    private let stopAfterDelivery: Bool
    private let resolved: @Sendable (DictationInputRoute?) -> Void
    private var followsSystem: [Bool] = []
    var bindingPolicies: [Bool] { lock.withLock { followsSystem } }
    var inputCallback: (@Sendable () -> Void)? { lock.withLock { changed } }
    var graphCount: Int { lock.withLock { graphs } }
    var startCount: Int { lock.withLock { starts } }
    var observationStopped: Bool { lock.withLock { stopped } }

    init(route: DictationInputRoute? = DictationInputRoute(device: 77, uid: "built-in"), firstSample: Float = 0.25,
         stopAfterDelivery: Bool = false,
         resolved: @escaping @Sendable (DictationInputRoute?) -> Void = { _ in },
         created: @escaping @Sendable (Int) -> Void = { _ in },
         started: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.route = route
        self.resolved = resolved
        self.firstSample = firstSample
        self.stopAfterDelivery = stopAfterDelivery
        self.created = created
        self.started = started
    }

    func change(to route: DictationInputRoute?, notify: Bool = true) {
        let callback = lock.withLock { self.route = route; return changed }
        if notify { callback?() }
    }

    func worker() -> DictationCaptureWorker {
        DictationCaptureWorker(mute: DictationOutputMute(control: UnavailableCaptureOutput()),
            playback: DictationMediaPlayback(command: { _, _ in "{\"status\":\"ignored\"}" }),
            resolveInput: { _ in
                let route = self.lock.withLock { self.route }
                self.resolved(route)
                return route
            },
            observeInputs: { callback in
                self.lock.withLock { self.changed = callback }
                return RouteTestObservation(stop: { self.lock.withLock { self.stopped = true; self.changed = nil } })
            },
            makeGraph: { _, followsSystem, relay, _ in
                let (index, route) = self.lock.withLock {
                    self.graphs += 1
                    self.followsSystem.append(followsSystem)
                    return (self.graphs, self.route)
                }
                self.created(index)
                return SyntheticCaptureGraph(rate: route?.sampleRate ?? 48_000,
                                             channels: route?.channels ?? 1) { graph in
                    let count = self.lock.withLock { self.starts += 1; return self.starts }
                    try graph.deliver(to: relay, sample: count == 1 ? self.firstSample : 0.25)
                    if self.stopAfterDelivery { graph.stop() }
                    self.started(count)
                }
            })
    }
}

final class DictationInputResolutionTests: XCTestCase {
    func testIneligibleOrReusedChosenDeviceFallsBackToAUsableInput() {
        let builtIn = DictationInputRoute(device: 77, uid: "built-in")
        let usb = DictationInputRoute(device: 90, uid: "usb")
        let reused = DictationInputRoute(device: 90, uid: "other-device")
        // A dead, output-only or zero-input-channel device has no usable snapshot.
        for snapshot in [usb, reused, nil] {
            let route = DictationInputRoute.resolve("usb", device: { _ in 90 }, system: { 77 },
                snapshot: { $0 == 77 ? builtIn : snapshot })
            XCTAssertEqual(route, snapshot == usb ? usb : builtIn)
        }
    }

    func testChosenDeviceReturnsAfterReconnectWithoutOverwritingThePreference() {
        let usb = DictationInputRoute(device: 90, uid: "usb")
        let builtIn = DictationInputRoute(device: 77, uid: "built-in")
        for connected in [true, false, true] {
            let route = DictationInputRoute.resolve("usb", device: { _ in connected ? 90 : nil }, system: { 77 },
                snapshot: { $0 == 77 ? builtIn : usb })
            XCTAssertEqual(route, connected ? usb : builtIn)
        }
    }

    func testValidExplicitChoiceDoesNotConsultTheSystemDefault() {
        var systemReads = 0
        let route = DictationInputRoute.resolve("usb", device: { _ in 90 },
            system: { systemReads += 1; return 77 }, snapshot: { DictationInputRoute(device: $0, uid: "usb") })
        XCTAssertEqual(route?.device, 90)
        XCTAssertEqual(systemReads, 0)
    }

    func testNoUsableDefaultReturnsNoInput() {
        XCTAssertNil(DictationInputRoute.resolve("usb", device: { _ in nil }, system: { nil }, snapshot: { _ in nil }))
        XCTAssertNil(DictationInputRoute.resolve(nil, device: { _ in 90 }, system: { 77 }, snapshot: { _ in nil }))
    }
}

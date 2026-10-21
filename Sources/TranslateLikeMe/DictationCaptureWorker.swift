import AVFoundation
import CoreAudio
import Foundation
import os

private let captureLog = Logger.app("dictation")

// The prepared engine's tap stays installed between holds. It forwards audio
// only while a hold's sink is attached, so a prepared idle engine writes nothing.
final class DictationTapRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: DictationAudioFile?
    private var ended: (@Sendable (Bool) -> Void)?

    func attach(_ sink: DictationAudioFile, ended: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { (self.sink, self.ended) = (sink, ended) }
    }

    func detach() { lock.withLock { (sink, ended) = (nil, nil) } }

    func fail() {
        let ended = lock.withLock {
            defer { (sink, self.ended) = (nil, nil) }
            return self.ended
        }
        ended?(false)
    }

    func deliver(_ buffer: AVAudioPCMBuffer) {
        let (sink, ended) = lock.withLock { (self.sink, self.ended) }
        if let sink, let success = sink.append(buffer) { ended?(success) }
    }
}

// All engine, file and observer state belongs to queue, including teardown.
// Only the locked request, relay and file sink are shared with the UI or tap.
// Between holds the raw input stays initialized but stopped: `prepare()`
// opens no microphone, and the press only starts the hardware. Voice
// processing was removed because its initialization took about a second per
// press and a prepared voice-processing unit kept media ducked while idle
// (`docs/dictation-startup.md`).
final class DictationCaptureWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.wiltodelta.translatelikeme.capture", qos: .userInitiated)
    private let relay = DictationTapRelay()
    private let mute = DictationOutputMute()
    private var engine: AVAudioEngine?
    private var format: AVAudioFormat?
    private var inputDevice: AudioDeviceID?
    private var generation = 0
    private var keepsPrepared = false
    private var capture: DictationAudioFile?
    private var current: DictationCaptureRequest?
    private var observer: NSObjectProtocol?

    init() { queue.async { [self] in mute.recoverInterrupted() } }

    // Rebuilding after wake replaces a graph whose device may have gone stale.
    func prepare(rebuild: Bool) {
        queue.async { [self] in
            keepsPrepared = true
            guard capture == nil else { return }
            if rebuild { tearDown() }
            prepareIdle()
        }
    }

    func release() {
        queue.async { [self] in
            keepsPrepared = false
            if capture == nil { tearDown() }
        }
    }

    func start(_ request: DictationCaptureRequest, ended: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            current = request
            do {
                guard request.isActive else { throw CancellationError() }
                try startEngine(request, ended: ended)
            } catch {
                request.fail(error)
                if !(error is CancellationError) {
                    captureLog.error("Microphone startup failed: \(String(describing: error), privacy: .public)")
                }
                discardCurrent()
                if request.isActive { ended(false) }
                // A graph that failed to start may pass the stale check; never reuse it.
                tearDown()
                settle()
            }
        }
    }

    private func startEngine(_ request: DictationCaptureRequest,
                             ended: @escaping @Sendable (Bool) -> Void) throws {
        let started = ContinuousClock.now
        if isStale { tearDown() }
        let (engine, format) = try prepared()
        let capture = try DictationAudioFile(url: request.url, format: format)
        self.capture = capture
        request.publish(capture)
        relay.attach(capture, ended: ended)
        mute.engage()
        try request.startWhileHeld { try engine.start() }
        let duration = started.duration(to: .now)
        let milliseconds = Double(duration.components.seconds) * 1_000 +
            Double(duration.components.attoseconds) / 1e15
        captureLog.notice("Dictation microphone started in \(milliseconds) ms")
    }

    func stop(_ request: DictationCaptureRequest) -> Task<URL, Error> {
        Task {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        if let error = request.failure { throw error }
                        guard current === request, let capture else { throw DictationError.microphone }
                        stopCapture()
                        try capture.finish()
                        self.capture = nil
                        continuation.resume(returning: request.url)
                    } catch { continuation.resume(throwing: error) }
                    settle()
                }
            }
        }
    }

    func discard(_ request: DictationCaptureRequest) {
        queue.async { [self] in
            guard current === request else { return }
            discardCurrent()
            settle()
        }
    }

    // Application termination must finish deletion before the process exits.
    func shutdown() {
        queue.sync {
            keepsPrepared = false
            discardCurrent()
            tearDown()
        }
    }

    private func discardCurrent() {
        stopCapture()
        try? capture?.finish()
        capture = nil
        if let current { try? FileManager.default.removeItem(at: current.url) }
        current = nil
    }

    private func stopCapture() {
        relay.detach()
        // Stopping also releases what `prepare()` allocated; spare an idle graph.
        if engine?.isRunning == true { engine?.stop() }
        mute.release()
    }

    // After a hold, or a release that arrived during one, keep the graph only if wanted.
    private func settle() {
        if keepsPrepared { prepareIdle() } else { tearDown() }
    }

    // Failures leave the graph unbuilt; the next press builds it again.
    private func prepareIdle() {
        guard keepsPrepared, capture == nil else { return }
        do {
            let (engine, _) = try prepared()
            engine.prepare()
        } catch {
            captureLog.error("Microphone preparation failed: \(String(describing: error), privacy: .public)")
            tearDown()
        }
    }

    private func prepared() throws -> (AVAudioEngine, AVAudioFormat) {
        if let engine, let format { return (engine, format) }
        let device = defaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard Self.isUsable(input.outputFormat(forBus: 0)) else { throw DictationError.microphone }
        let relay = relay
        // A nil format taps whatever the bus has now. AirPods changed their input
        // format between a read and the tap (24 kHz, then 2 ch 44.1 kHz), and a
        // tap given the stale format raises an Objective-C exception, which Swift
        // cannot catch. A later change fails the sink's format check instead.
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { @Sendable buffer, _ in
            relay.deliver(buffer)
        }
        let format = input.outputFormat(forBus: 0)
        guard Self.isUsable(format) else {
            input.removeTap(onBus: 0)
            throw DictationError.microphone
        }
        generation += 1
        let generation = generation
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in self?.configurationChanged(generation) }
        }
        (self.engine, self.format, inputDevice) = (engine, format, device)
        return (engine, format)
    }

    private func configurationChanged(_ generation: Int) {
        guard generation == self.generation, let engine else { return }
        if let current, capture != nil {
            guard !engine.isRunning || engine.inputNode.outputFormat(forBus: 0) != format else { return }
            captureLog.error("Audio engine stopped or changed its input format during dictation")
            current.fail(DictationError.microphone)
            relay.fail()
        } else {
            // A device or format change while idle invalidates the prepared graph.
            tearDown()
            settle()
        }
    }

    // A prepared engine stays bound to the input that was default when it was
    // built. Its I/O unit reports the engine's own aggregate device, not that input.
    private var isStale: Bool {
        guard let engine, let format else { return false }
        return defaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice) != inputDevice
            || engine.inputNode.outputFormat(forBus: 0) != format
    }

    private static func isUsable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    private func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        (engine, format, inputDevice) = (nil, nil, nil)
    }
}

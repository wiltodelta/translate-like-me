import AVFoundation
import CoreAudio
import Foundation
import os
import Synchronization

private let captureLog = Logger.app("dictation")

// The prepared engine's tap stays installed between holds. It forwards audio
// only while a hold's sink is attached, so a prepared idle engine writes nothing.
final class DictationTapRelay: @unchecked Sendable {
    private let lock = NSLock()
    // Lets the real-time sink skip the lock once the hold has heard audio.
    private let listening = Atomic(false)
    private var sink: DictationAudioFile?
    private var ended: (@Sendable (Bool) -> Void)?

    func attach(_ sink: DictationAudioFile, ended: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { (self.sink, self.ended) = (sink, ended) }
        listening.store(true, ordering: .relaxed)
    }

    func detach() {
        listening.store(false, ordering: .relaxed)
        lock.withLock { (sink, ended) = (nil, nil) }
    }

    // The tap delivers 100 ms buffers; the sink sees each 512-frame I/O cycle,
    // so the first nonzero sample shows Listening about 100 ms sooner.
    func hear(_ audio: UnsafePointer<AudioBufferList>) {
        guard listening.load(ordering: .relaxed), let sink = lock.withLock({ self.sink }) else { return }
        if !sink.hasSignal {
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audio))
            let sound = buffers.contains { buffer in
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return false }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                return UnsafeBufferPointer(start: data, count: count).contains { $0 != 0 }
            }
            guard sound else { return }
            sink.markSignal()
        }
        listening.store(false, ordering: .relaxed)
    }

    func deliver(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime? = nil) {
        let (sink, ended) = lock.withLock { (self.sink, self.ended) }
        if let sink, let success = sink.append(buffer, at: time) { ended?(success) }
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
    private var relay = DictationTapRelay()
    typealias MakeGraph = @Sendable (AudioDeviceID?, Bool, DictationTapRelay,
                                    @escaping @Sendable () -> Void) throws -> any DictationInputGraph
    private let makeGraph: MakeGraph
    typealias ObserveInputs = @Sendable (@escaping @Sendable () -> Void) -> any DictationInputWatching
    private let resolveInput: @Sendable (String?) -> DictationInputRoute?
    private var inputObserver: (any DictationInputWatching)?
    private let mute: DictationOutputMute
    private var engine: (any DictationInputGraph)?
    private var format: AVAudioFormat?
    private var inputRoute: DictationInputRoute?
    private var generation = 0
    private var keepsPrepared = false
    private var capture: DictationAudioFile?
    private var current: DictationCaptureRequest?
    private var preferredInput: String?
    private var captureEnded: (@Sendable (Bool) -> Void)?
    private var startupRestarts = 0

    init(mute: DictationOutputMute = DictationOutputMute(),
         resolveInput: @escaping @Sendable (String?) -> DictationInputRoute? = { DictationInputRoute.resolve($0) },
         observeInputs: @escaping ObserveInputs = { DictationInputObserver(changed: $0) },
         makeGraph: @escaping MakeGraph = { try AVDictationInputGraph(device: $0, followsSystem: $1,
                                                                     relay: $2, changed: $3) }) {
        self.resolveInput = resolveInput
        self.mute = mute
        self.makeGraph = makeGraph
        queue.async { [self] in
            self.mute.recoverInterrupted()
            inputObserver = observeInputs { [weak self] in
                self?.queue.async { [weak self] in self?.inputDevicesChanged() }
            }
        }
    }

    // The chosen microphone's UID, nil for the system input; the next build or press applies it.
    func useInput(_ uid: String?) { queue.async { [self] in preferredInput = uid } }

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
            captureEnded = ended
            startupRestarts = 0
            do {
                guard request.isActive else { throw CancellationError() }
                try startEngine(request, ended: ended)
            } catch { startFailed(request, error: error, ended: ended) }
        }
    }

    private func startFailed(_ request: DictationCaptureRequest, error: Error,
                             ended: @escaping @Sendable (Bool) -> Void) {
        request.fail(error)
        if !(error is CancellationError) {
            captureLog.error("Microphone startup failed: \(String(describing: error), privacy: .public)")
        }
        discardCurrent()
        if request.isActive { ended(false) }
        tearDown()
        settle()
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
        try request.startIfActive { try engine.start() }
        // Release/cancel stays nonblocking even during a slow hardware start.
        // Drain any captured frames on stop, but stop the microphone immediately.
        if !request.isActive { stopCapture() }
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
                        guard engine?.isRunning == true, !isStale else {
                            request.fail(DictationError.microphone)
                            stopCapture()
                            throw DictationError.microphone
                        }
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
            inputObserver?.stop()
            inputObserver = nil
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
        captureEnded = nil
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
        mute.recoverInterrupted()
        do {
            let (engine, _) = try prepared()
            engine.prepare()
        } catch {
            captureLog.error("Microphone preparation failed: \(String(describing: error), privacy: .public)")
            tearDown()
        }
    }

    private func prepared() throws -> (any DictationInputGraph, AVAudioFormat) {
        if let engine, let format { return (engine, format) }
        guard let route = resolveInput(preferredInput) else { throw DictationError.microphone }
        let device = route.device
        generation += 1
        let generation = generation
        // Old tap callbacks must never see a replacement graph's recording.
        let relay = DictationTapRelay()
        self.relay = relay
        let engine = try makeGraph(device, route.uid != preferredInput, relay) { [weak self] in
            self?.queue.async { [weak self] in self?.configurationChanged(generation) }
        }
        let format = engine.format
        let selection = preferredInput == nil ? "system" : route.uid == preferredInput ? "chosen" : "fallback"
        captureLog.notice("""
            Dictation input prepared: transport=\(audioDeviceTransport(device), privacy: .public) \
            selection=\(selection, privacy: .public) rate=\(format.sampleRate) channels=\(format.channelCount)
            """)
        (self.engine, self.format, inputRoute) = (engine, format, route)
        inputObserver?.watch(route)
        return (engine, format)
    }

    private func inputDevicesChanged() {
        if engine == nil {
            if keepsPrepared, capture == nil { prepareIdle() }
        } else if isStale {
            configurationChanged(generation)
        }
    }

    private func configurationChanged(_ generation: Int) {
        guard generation == self.generation, let engine else { return }
        if let current, let capture {
            guard !engine.isRunning || isStale else { return }
            // Stop callbacks and drain any in-flight write before deciding
            // whether this hold has heard audio and can safely start over.
            tearDown()
            try? capture.finish()
            // Bluetooth can change from its playback format to HFP only after
            // start(). Discard only exact digital silence, with a finite budget per hold.
            if current.isActive, !capture.hasSignal, startupRestarts < 2, let ended = captureEnded {
                startupRestarts += 1
                captureLog.notice("Dictation rebuilding input after a startup configuration change")
                self.capture = nil
                do { try startEngine(current, ended: ended) } catch {
                    startFailed(current, error: error, ended: ended)
                }
                return
            }
            captureLog.error("Audio engine stopped or changed its input format during dictation")
            current.fail(DictationError.microphone)
            captureEnded?(false)
        } else {
            // A device or format change while idle invalidates the prepared graph.
            tearDown()
            settle()
        }
    }

    // A prepared engine stays bound to the input it was built on: the chosen
    // microphone, or the system input when none is chosen or it is disconnected.
    // Its I/O unit reports the engine's own aggregate device, not that input.
    private var isStale: Bool {
        guard let engine, let format else { return false }
        return resolveInput(preferredInput) != inputRoute
            || engine.format != format
    }

    private func tearDown() {
        generation += 1
        relay.detach()
        inputObserver?.watch(nil)
        engine?.shutdown()
        (engine, format, inputRoute) = (nil, nil, nil)
    }
}

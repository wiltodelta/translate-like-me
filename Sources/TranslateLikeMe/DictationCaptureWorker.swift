import AVFoundation
import Foundation
import os

private let captureLog = Logger.app("dictation")

// All engine, file and observer state belongs to queue, including teardown.
// Only the locked request and file sink are shared with the UI or audio tap.
final class DictationCaptureWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.wiltodelta.translatelikeme.capture", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var capture: DictationAudioFile?
    private var current: DictationCaptureRequest?
    private var observer: NSObjectProtocol?

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
            }
        }
    }

    private func startEngine(_ request: DictationCaptureRequest,
                             ended: @escaping @Sendable (Bool) -> Void) throws {
        let started = ContinuousClock.now
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        do { try input.setVoiceProcessingEnabled(true) } catch { throw DictationError.voiceProcessing }
        guard input.isVoiceProcessingEnabled, engine.outputNode.isVoiceProcessingEnabled else {
            throw DictationError.voiceProcessing
        }
        input.isVoiceProcessingBypassed = false
        input.isVoiceProcessingAGCEnabled = false
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .max)
        let format = input.outputFormat(forBus: 0)
        DictationRecorder.connectSilentOutput(to: engine, format: format)
        let capture = try DictationAudioFile(url: request.url, format: format)
        self.capture = capture
        request.publish(capture)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { @Sendable buffer, _ in
            if let success = capture.append(buffer) { ended(success) }
        }
        try request.startWhileHeld { try engine.start() }
        let duration = started.duration(to: .now)
        let milliseconds = Double(duration.components.seconds) * 1_000 +
            Double(duration.components.attoseconds) / 1e15
        captureLog.notice("Dictation microphone started in \(milliseconds) ms")
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.current === request, let engine = self.engine,
                      !engine.isRunning || engine.inputNode.outputFormat(forBus: 0) != self.capture?.format else {
                    return
                }
                captureLog.error("Audio engine stopped or changed its input format during dictation")
                request.fail(DictationError.microphone)
                ended(false)
            }
        }
    }

    func stop(_ request: DictationCaptureRequest) -> Task<URL, Error> {
        Task {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        if let error = request.failure { throw error }
                        guard current === request, let capture else { throw DictationError.microphone }
                        stopEngine()
                        try capture.finish()
                        self.capture = nil
                        continuation.resume(returning: request.url)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    func discard(_ request: DictationCaptureRequest) {
        queue.async { [self] in
            guard current === request else { return }
            discardCurrent()
        }
    }

    // Application termination must finish deletion before the process exits.
    func shutdown() { queue.sync { discardCurrent() } }

    private func discardCurrent() {
        stopEngine()
        try? capture?.finish()
        capture = nil
        if let current { try? FileManager.default.removeItem(at: current.url) }
        current = nil
    }

    private func stopEngine() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let engine {
            engine.stop()
            if capture != nil { engine.inputNode.removeTap(onBus: 0) }
            do { try engine.inputNode.setVoiceProcessingEnabled(false) } catch {
                captureLog.error("Voice processing teardown failed: \(String(describing: error), privacy: .public)")
            }
            self.engine = nil
        }
    }
}

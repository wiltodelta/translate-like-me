import AVFoundation
import Foundation
import os

private let captureLog = Logger.app("dictation")

@MainActor
protocol DictationRecording: AnyObject {
    var onEnd: ((Bool) -> Void)? { get set }
    var level: Double { get }
    var isDeliveringAudio: Bool { get }
    func requestPermission() async -> Bool
    func start() throws
    func stop() throws -> URL
    func discard()
}

// Capture only the voice-processed input, never route the microphone to speakers.
// Only the current recording lives on disk, until recognition or cancellation.
@MainActor
final class DictationRecorder: DictationRecording {
    private var engine: AVAudioEngine?
    private var capture: DictationAudioFile?
    private var configurationObserver: NSObjectProtocol?
    private var file: URL?
    var onEnd: ((Bool) -> Void)?

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        discard()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tlm-dictation-\(UUID().uuidString).wav")
        file = url
        do {
            try startEngine(at: url)
        } catch {
            discard()
            throw error
        }
    }

    private func startEngine(at url: URL) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            captureLog.error("Voice processing setup failed: \(String(describing: error), privacy: .public)")
            throw DictationError.voiceProcessing
        }
        guard input.isVoiceProcessingEnabled, engine.outputNode.isVoiceProcessingEnabled else {
            throw DictationError.voiceProcessing
        }
        input.isVoiceProcessingBypassed = false
        // Avoid automatic level boosts to quiet residual audio and room noise.
        input.isVoiceProcessingAGCEnabled = false
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .max)
        // Voice processing can change the device format. Read it after enabling,
        // and let WhisperKit convert the processed WAV to 16 kHz mono on read.
        let format = input.outputFormat(forBus: 0)
        Self.connectSilentOutput(to: engine, format: format)
        let capture = try DictationAudioFile(url: url, format: format)
        self.engine = engine
        self.capture = capture
        input.installTap(onBus: 0, bufferSize: 1_024, format: capture.format) { @Sendable [weak self] buffer, _ in
            guard let success = capture.append(buffer) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.file == url, self.capture === capture else { return }
                self.onEnd?(success)
            }
        }
        do {
            try engine.start()
        } catch {
            captureLog.error("Audio engine startup failed: \(String(describing: error), privacy: .public)")
            throw DictationError.microphone
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.capture === capture, let engine = self.engine,
                      !engine.isRunning || engine.inputNode.outputFormat(forBus: 0) != capture.format else { return }
                captureLog.error("Audio engine stopped or changed its input format during dictation")
                self.onEnd?(false)
            }
        }
    }

    static func connectSilentOutput(to engine: AVAudioEngine, format: AVAudioFormat) {
        // Voice processing needs a rendered output clock even for capture-only
        // dictation. An input tap alone can leave the downlink without timestamps.
        let silence = AVAudioSourceNode { @Sendable isSilent, _, _, audioBuffers in
            isSilent.pointee = true
            for buffer in UnsafeMutableAudioBufferListPointer(audioBuffers) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
        engine.attach(silence)
        let mixer = engine.mainMixerNode
        // VoiceProcessingIO requires matching client input/output formats. The
        // mixer's default output can differ in both rate and channel count.
        engine.connect(mixer, to: engine.outputNode, format: format)
        engine.connect(silence, to: mixer, format: format)
    }

    var level: Double { capture?.level ?? 0 }
    var isDeliveringAudio: Bool { capture?.isDeliveringAudio ?? false }

    func stop() throws -> URL {
        guard let file, let capture else { throw DictationError.microphone }
        stopEngine()
        try capture.finish()
        self.capture = nil
        return file
    }

    func discard() {
        stopEngine()
        try? capture?.finish()
        capture = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }

    private func stopEngine() {
        onEnd = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            do {
                try engine.inputNode.setVoiceProcessingEnabled(false)
            } catch {
                captureLog.error("Voice processing teardown failed: \(String(describing: error), privacy: .public)")
            }
            self.engine = nil
        }
    }
}

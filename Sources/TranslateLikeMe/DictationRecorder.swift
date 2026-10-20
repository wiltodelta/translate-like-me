import AVFoundation
import Foundation

@MainActor
protocol DictationRecording: AnyObject {
    var onEnd: ((Bool) -> Void)? { get set }
    var level: Double { get }
    var isDeliveringAudio: Bool { get }
    func requestPermission() async -> Bool
    func start() throws
    func stop() throws -> Task<URL, Error>
    func discard()
    func shutdown()
}

// The serial capture worker owns every AVAudioEngine access. MainActor owns
// callbacks and the current request. A press enqueues hardware initialization.
@MainActor
final class DictationRecorder: DictationRecording {
    private let worker = DictationCaptureWorker()
    private var request: DictationCaptureRequest?
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
        let request = DictationCaptureRequest()
        self.request = request
        worker.start(request) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self, self.request === request else { return }
                self.onEnd?(success)
            }
        }
    }

    var level: Double { request?.sink?.level ?? 0 }
    var isDeliveringAudio: Bool { request?.sink?.isDeliveringAudio ?? false }

    func stop() throws -> Task<URL, Error> {
        guard let request else { throw DictationError.microphone }
        request.end()
        onEnd = nil
        return worker.stop(request)
    }

    func discard() {
        onEnd = nil
        guard let request else { return }
        self.request = nil
        request.end()
        worker.discard(request)
    }

    func shutdown() {
        request?.end()
        onEnd = nil
        worker.shutdown()
        request = nil
    }

    nonisolated static func connectSilentOutput(to engine: AVAudioEngine, format: AVAudioFormat) {
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

}

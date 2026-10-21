import AVFoundation
import Foundation

@MainActor
protocol DictationRecording: AnyObject {
    var onEnd: ((Bool) -> Void)? { get set }
    var level: Double { get }
    var isDeliveringAudio: Bool { get }
    func requestPermission() async -> Bool
    func warmUp(rebuild: Bool)
    func coolDown()
    func start() throws
    func stop() throws -> Task<URL, Error>
    func discard()
    func shutdown()
}

// The serial capture worker owns every AVAudioEngine access. MainActor owns
// callbacks and the current request. Warm-up prepares the input between holds
// without opening the microphone; a press enqueues only the hardware start.
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

    // Only an existing grant is used: initializing input must never prompt.
    func warmUp(rebuild: Bool) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        worker.prepare(rebuild: rebuild)
    }

    func coolDown() { worker.release() }

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
}

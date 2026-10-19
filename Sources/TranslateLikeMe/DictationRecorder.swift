import AVFoundation
import Foundation

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

// AVAudioRecorder owns hardware conversion and final file draining. Only the
// current recording lives on disk; it is removed after recognition or cancel.
@MainActor
final class DictationRecorder: NSObject, AVAudioRecorderDelegate, DictationRecording {
    private var recorder: AVAudioRecorder?
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
            let capture = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            capture.delegate = self
            capture.isMeteringEnabled = true
            guard capture.record(forDuration: 300) else { throw DictationError.microphone }
            recorder = capture
        } catch {
            discard()
            throw error
        }
    }

    var level: Double {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        return min(1, max(0, (Double(recorder.averagePower(forChannel: 0)) + 60) / 60))
    }

    var isDeliveringAudio: Bool { (recorder?.currentTime ?? 0) > 0 }

    func stop() throws -> URL {
        guard let file else { throw DictationError.microphone }
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        return file
    }

    func discard() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.file == url else { return }
            self.onEnd?(flag)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.file == url else { return }
            self.onEnd?(false)
        }
    }
}

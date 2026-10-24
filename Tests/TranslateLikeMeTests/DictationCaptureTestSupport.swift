import AVFoundation
import CoreAudio
import XCTest
@testable import TranslateLikeMe

// Capture fixtures stay on the worker queue and never open real audio devices.
final class SyntheticCaptureGraph: DictationInputGraph {
    var format: AVAudioFormat
    var isRunning = false
    private let onStart: (SyntheticCaptureGraph) throws -> Void

    init(rate: Double, channels: UInt32 = 1, start: @escaping (SyntheticCaptureGraph) throws -> Void) {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                               interleaved: false, channelLayout: layout)
        onStart = start
    }

    func prepare() {}
    func start() throws { isRunning = true; try onStart(self) }
    func stop() { isRunning = false }
    func shutdown() { stop() }
    func deliver(to relay: DictationTapRelay, sample: Float = 0.25) throws {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<160 { channels[channel][frame] = sample }
        }
        relay.deliver(buffer)
    }
}

struct UnavailableCaptureOutput: DictationOutputControl {
    func defaultOutput() -> AudioObjectID? { nil }
    func isMuted(_ device: AudioObjectID) -> Bool? { nil }
    func setMuted(_ device: AudioObjectID, _ muted: Bool) -> Bool { false }
    func uid(of device: AudioObjectID) -> String? { nil }
    func device(uid: String) -> AudioObjectID? { nil }
}

final class RouteTestObservation: DictationInputWatching {
    private let onStop: () -> Void
    init(stop: @escaping () -> Void = {}) { onStop = stop }
    func watch(_ route: DictationInputRoute?) {}
    func stop() { onStop() }
}

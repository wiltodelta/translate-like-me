import AVFoundation
import Foundation

// NSLock serializes the non-real-time tap's writes with meter reads and close.
// The tap never enters the main actor. Closing rejects late audio callbacks.
final class DictationAudioFile: @unchecked Sendable {
    let format: AVAudioFormat
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let frameLimit: AVAudioFramePosition
    private var frames: AVAudioFramePosition = 0
    private var meter: Double = 0
    private var ended = false
    private var failure: Error?

    init(url: URL, format: AVAudioFormat, maximumDuration: TimeInterval = 300) throws {
        guard format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              maximumDuration > 0 else { throw DictationError.microphone }
        self.format = format
        frameLimit = AVAudioFramePosition(format.sampleRate * maximumDuration)
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false // WAV stores interleaved samples; processing buffers do not.
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    var level: Double { lock.withLock { meter } }
    var isDeliveringAudio: Bool { lock.withLock { frames > 0 } }

    // nil means continue; a terminal success/failure is reported exactly once.
    func append(_ buffer: AVAudioPCMBuffer) -> Bool? {
        lock.withLock {
            guard !ended, let file else { return nil }
            guard buffer.format == format else {
                failure = DictationError.microphone
                ended = true
                return false
            }
            let originalLength = buffer.frameLength
            buffer.frameLength = AVAudioFrameCount(min(AVAudioFramePosition(originalLength), frameLimit - frames))
            defer { buffer.frameLength = originalLength }
            guard buffer.frameLength > 0 else { return nil }
            do {
                try file.write(from: buffer)
            } catch {
                failure = error
                ended = true
                return false
            }
            frames += AVAudioFramePosition(buffer.frameLength)
            meter = Self.level(of: buffer)
            if frames >= frameLimit {
                ended = true
                return true
            }
            return nil
        }
    }

    func finish() throws {
        try lock.withLock {
            ended = true
            file = nil // Finalize the WAV header before recognition opens it.
            if let failure { throw failure }
        }
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var energy: Double = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                let sample = Double(channels[channel][frame])
                energy += sample * sample
            }
        }
        let mean = energy / (Double(buffer.frameLength) * Double(buffer.format.channelCount))
        let decibels = 10 * log10(max(mean, 1e-12))
        return min(1, max(0, (decibels + 60) / 60))
    }
}

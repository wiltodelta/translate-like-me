import AVFoundation
import Foundation
import Synchronization
import os

// NSLock serializes the non-real-time tap's writes with meter reads and close.
// The tap never enters the main actor. Closing rejects late audio callbacks.
final class DictationAudioFile: @unchecked Sendable {
    let format: AVAudioFormat
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let frameLimit: AVAudioFramePosition
    private var frames: AVAudioFramePosition = 0
    private var meter: Double = 0
    // Release-tail inputs: the quietest and loudest buffers, and the quiet run at the end.
    private var floor = Double.infinity
    private var peak: Double = 0
    private var quietFrames: AVAudioFramePosition = 0
    private var ended = false
    private var failure: Error?
    private var metrics: DictationAudioMetrics
    // Set by the first write or, sooner, the real-time sink, without the write
    // lock, which file I/O can hold.
    private let heard = Atomic(false)
    private let signal = Atomic(false)
    private let listening = Atomic(false)

    init(url: URL, format: AVAudioFormat, maximumDuration: TimeInterval = 300) throws {
        guard format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              maximumDuration > 0 else { throw DictationError.microphone }
        self.format = format
        metrics = DictationAudioMetrics(rate: format.sampleRate, channels: Int(format.channelCount))
        frameLimit = AVAudioFramePosition(format.sampleRate * maximumDuration)
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false // WAV stores interleaved samples; processing buffers do not.
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    var level: Double { lock.withLock { meter } }
    var diagnostics: DictationAudioMetrics { lock.withLock { metrics } }
    var isDeliveringAudio: Bool { heard.load(ordering: .relaxed) }
    var hasSignal: Bool { signal.load(ordering: .relaxed) }
    // A cold AirPods microphone sent about 0.5 s of exact zeros first, and speech
    // in that time was lost (2026-10-25). A hardware-muted input never sends more
    // than zeros, so a second of them also counts as listening.
    var isListening: Bool { listening.load(ordering: .relaxed) }
    func markSignal() {
        signal.store(true, ordering: .relaxed)
        heard.store(true, ordering: .relaxed)
        listening.store(true, ordering: .relaxed)
    }

    // nil means continue; a terminal success/failure is reported exactly once.
    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime? = nil) -> Bool? {
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
            let measurement = metrics.observe(buffer, at: time)
            guard measurement.valid else {
                failure = DictationError.microphone
                ended = true
                return false
            }
            do {
                try file.write(from: buffer)
            } catch {
                failure = error
                ended = true
                return false
            }
            let count = AVAudioFramePosition(buffer.frameLength)
            frames += count
            heard.store(true, ordering: .relaxed)
            if measurement.hasSignal { signal.store(true, ordering: .relaxed) }
            if measurement.hasSignal || frames >= AVAudioFramePosition(format.sampleRate) {
                listening.store(true, ordering: .relaxed)
            }
            meter = measurement.level
            track(meter, frames: count)
            if frames >= frameLimit {
                ended = true
                return true
            }
            return nil
        }
    }

    // How long the recording has been quiet at its end, zero while no buffer
    // was quiet enough below the loudest to tell speech from the room.
    var trailingQuiet: TimeInterval {
        lock.withLock {
            guard peak - floor >= Self.contrast else { return 0 }
            return Double(quietFrames) / format.sampleRate
        }
    }

    // Levels run 0...1 over 60 dB: quiet is within 9 dB of the floor, which
    // must sit at least 15 dB under the peak. The first buffer can hold the
    // microphone's start-up silence, so it never sets the floor.
    private static let margin = 0.15
    private static let contrast = 0.25

    private func track(_ level: Double, frames count: AVAudioFramePosition) {
        peak = max(peak, level)
        if frames > count, level < floor {
            // A lower floor starts the run again: earlier buffers were judged against a louder one.
            floor = level
            quietFrames = count
        } else if level > floor + Self.margin {
            quietFrames = 0
        } else {
            quietFrames += count
        }
    }

    func finish() throws {
        try lock.withLock {
            ended = true
            if file != nil {
                Logger.app("dictation").notice("""
                    Dictation native audio: writtenFrames=\(self.frames) \(self.metrics.summary, privacy: .public)
                    """)
            }
            file = nil // Finalize the WAV header before recognition opens it.
            if let failure { throw failure }
        }
    }
}

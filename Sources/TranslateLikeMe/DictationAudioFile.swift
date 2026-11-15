import AVFoundation
import Foundation
import Synchronization
import os

// NSLock serializes the non-real-time tap's writes with meter reads and close.
// The tap never enters the main actor. Closing rejects late audio callbacks.
final class DictationAudioFile: @unchecked Sendable {
    final class Flags: Sendable {
        let heard = Atomic(false)
        let signal = Atomic(false)
        let listening = Atomic(false)

        func reset() {
            heard.store(false, ordering: .relaxed)
            signal.store(false, ordering: .relaxed)
            listening.store(false, ordering: .relaxed)
        }
        func markDelivered() { heard.store(true, ordering: .relaxed) }
        func markSignal() {
            signal.store(true, ordering: .relaxed)
            heard.store(true, ordering: .relaxed)
            listening.store(true, ordering: .relaxed)
        }
    }

    let format: AVAudioFormat
    let flags = Flags()
    private var streamFlags: Flags?
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let frameLimit: AVAudioFramePosition
    private let trackWindowFrames: AVAudioFramePosition
    private var frames: AVAudioFramePosition = 0
    private var meter: Double = 0
    // Release-tail inputs: the quietest and loudest 100 ms windows, and the quiet run at the end.
    private var floor = Double.infinity
    private var peak: Double = 0
    private var quietFrames: AVAudioFramePosition = 0
    private var pendingTrackEnergy: Double = 0
    private var pendingTrackFrames: AVAudioFramePosition = 0
    private var ended = false
    private var failure: Error?
    private var metrics: DictationAudioMetrics

    init(url: URL, format: AVAudioFormat, maximumDuration: TimeInterval = 300) throws {
        guard format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              maximumDuration > 0 else { throw DictationError.microphone }
        self.format = format
        metrics = DictationAudioMetrics(rate: format.sampleRate, channels: Int(format.channelCount))
        frameLimit = AVAudioFramePosition(format.sampleRate * maximumDuration)
        trackWindowFrames = max(1, AVAudioFramePosition((format.sampleRate * 0.1).rounded()))
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false // WAV stores interleaved samples; processing buffers do not.
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    var level: Double { lock.withLock { meter } }
    var diagnostics: DictationAudioMetrics { lock.withLock { metrics } }
    var isDeliveringAudio: Bool {
        flags.heard.load(ordering: .relaxed)
            || lock.withLock { streamFlags }?.heard.load(ordering: .relaxed) == true
    }
    var hasSignal: Bool {
        flags.signal.load(ordering: .relaxed)
            || lock.withLock { streamFlags }?.signal.load(ordering: .relaxed) == true
    }
    // A cold AirPods microphone sent about 0.5 s of exact zeros first, and speech
    // in that time was lost (2026-10-25). A hardware-muted input never sends more
    // than zeros, so a second of them also counts as listening.
    var isListening: Bool {
        flags.listening.load(ordering: .relaxed)
            || lock.withLock { streamFlags }?.listening.load(ordering: .relaxed) == true
    }

    func attachStreamFlags(_ active: Flags) {
        lock.withLock { streamFlags = active }
    }

    func detachStreamFlags() {
        lock.withLock {
            if streamFlags?.heard.load(ordering: .relaxed) == true { flags.markDelivered() }
            if streamFlags?.signal.load(ordering: .relaxed) == true { flags.markSignal() }
            if streamFlags?.listening.load(ordering: .relaxed) == true {
                flags.listening.store(true, ordering: .relaxed)
            }
            streamFlags = nil
        }
    }

    func failFormat() -> Bool {
        lock.withLock {
            guard !ended else { return false }
            failure = DictationError.microphone
            ended = true
            return true
        }
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
            flags.markDelivered()
            if measurement.hasSignal {
                flags.markSignal()
            } else if frames >= AVAudioFramePosition(format.sampleRate) {
                flags.listening.store(true, ordering: .relaxed)
            }
            meter = measurement.level
            pendingTrackEnergy += measurement.energy
            pendingTrackFrames += count
            if pendingTrackFrames >= trackWindowFrames {
                let windowLevel = DictationAudioMetrics.normalizedLevel(
                    energy: pendingTrackEnergy,
                    samples: Int(pendingTrackFrames) * Int(format.channelCount)
                )
                track(windowLevel, frames: pendingTrackFrames)
                pendingTrackEnergy = 0
                pendingTrackFrames = 0
            }
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
            guard floor <= Self.maximumFloor, peak - floor >= Self.contrast else { return 0 }
            return Double(quietFrames) / format.sampleRate
        }
    }

    // Levels run 0...1 over 60 dB: quiet is within 9 dB of a room floor at or
    // below -39 dBFS, which must sit at least 15 dB under the peak. Mid-speech
    // consonants above -39 dBFS cannot set the floor and clip word endings, and
    // the first buffer never sets it because it can hold start-up silence.
    private static let margin = 0.15
    private static let contrast = 0.25
    private static let maximumFloor = 0.35

    private func track(_ level: Double, frames count: AVAudioFramePosition) {
        peak = max(peak, level)
        if frames > count, level <= Self.maximumFloor, level < floor {
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

import AVFoundation
import Foundation
import XCTest
@testable import TranslateLikeMe

final class DictationAudioFileTests: XCTestCase {
    func testFinalizedNativePCMCanBeReadAsModelInput() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let capture = try DictationAudioFile(url: url, format: format)
        XCTAssertFalse(capture.isDeliveringAudio)
        XCTAssertEqual(capture.level, 0)
        XCTAssertNil(capture.append(try buffer(format: format, frames: 4_800, value: 0.25)))
        XCTAssertTrue(capture.isDeliveringAudio)
        XCTAssertGreaterThan(capture.level, 0)
        XCTAssertLessThanOrEqual(capture.level, 1)
        try capture.finish()
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 4_800)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        let samples = try DictationAudioLoader.load(url)
        XCTAssertEqual(samples.count, 1_600)
        XCTAssertEqual(try XCTUnwrap(samples.dropFirst(100).first), 0.25, accuracy: 0.001)
    }

    // A cold AirPods microphone sent about 0.5 s of exact zeros before any sound (2026-10-25).
    func testListeningWaitsForSoundOrASecondOfZeros() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let quiet = temporaryFile()
        defer { try? FileManager.default.removeItem(at: quiet) }
        let muted = try DictationAudioFile(url: quiet, format: format)
        XCTAssertNil(muted.append(try buffer(format: format, frames: 8_000, value: 0)))
        XCTAssertTrue(muted.isDeliveringAudio)
        XCTAssertFalse(muted.isListening, "Half a second of zeros is a cold microphone, not sound")
        XCTAssertNil(muted.append(try buffer(format: format, frames: 8_000, value: 0)))
        XCTAssertTrue(muted.isListening, "A hardware-muted input still gets Listening after a second")
        try muted.finish()
        let spoken = temporaryFile()
        defer { try? FileManager.default.removeItem(at: spoken) }
        let speech = try DictationAudioFile(url: spoken, format: format)
        XCTAssertNil(speech.append(try buffer(format: format, frames: 160, value: 0.25)))
        XCTAssertTrue(speech.isListening)
        try speech.finish()
    }

    func testTrailingQuietNeedsContrastAndResetsOnSpeech() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let capture = try DictationAudioFile(url: url, format: format)
        let silence = try buffer(format: format, frames: 1_600, value: 0)
        let room = try buffer(format: format, frames: 1_600, value: 0.002)
        let speech = try buffer(format: format, frames: 1_600, value: 0.1)
        XCTAssertNil(capture.append(silence), "Start-up silence never sets the floor")
        XCTAssertNil(capture.append(speech))
        XCTAssertNil(capture.append(speech))
        XCTAssertEqual(capture.trailingQuiet, 0, "No quiet buffer yet to tell speech from the room")
        XCTAssertNil(capture.append(room))
        XCTAssertEqual(capture.trailingQuiet, 0.1, accuracy: 0.001)
        XCTAssertNil(capture.append(room))
        XCTAssertEqual(capture.trailingQuiet, 0.2, accuracy: 0.001)
        XCTAssertNil(capture.append(speech))
        XCTAssertEqual(capture.trailingQuiet, 0, "Speech restarts the quiet run")
        try capture.finish()
    }

    func testTrailingQuietRejectsMidSpeechConsonantsAsRoomFloor() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let capture = try DictationAudioFile(url: url, format: format)
        let vowel = try buffer(format: format, frames: 1_600, value: 0.5)
        let consonant = try buffer(format: format, frames: 1_600, value: 0.02)
        let murmured = try buffer(format: format, frames: 1_600, value: 0.025)
        let room = try buffer(format: format, frames: 1_600, value: 0.002)
        XCTAssertNil(capture.append(vowel))
        XCTAssertNil(capture.append(consonant))
        XCTAssertNil(capture.append(murmured))
        XCTAssertNil(capture.append(murmured))
        XCTAssertEqual(capture.trailingQuiet, 0, "Unvoiced consonants above -39 dBFS must not set a fake room floor")
        XCTAssertNil(capture.append(room))
        XCTAssertEqual(capture.trailingQuiet, 0.1, accuracy: 0.001)
        try capture.finish()
    }

    func testRelayStreamsSinkCyclesOnlyForAttachedHoldAndFlushesShortHold() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let capture = try DictationAudioFile(url: url, format: format)
        let relay = DictationTapRelay()
        let silence = try buffer(format: format, frames: 512, value: 0)
        let sound = try buffer(format: format, frames: 512, value: 0.01)
        relay.receive(nil, frames: 512, audio: sound.audioBufferList)
        XCTAssertFalse(capture.isDeliveringAudio, "No hold attached")
        relay.attach(capture) { _ in }
        relay.receive(nil, frames: 512, audio: silence.audioBufferList)
        XCTAssertTrue(capture.isDeliveringAudio, "Muted or cold-start zero buffers still prove the graph runs")
        XCTAssertFalse(capture.isListening, "Start-up zeros do not show Listening before sound or 1 s")
        for _ in 0..<250 {
            relay.receive(nil, frames: 512, audio: sound.audioBufferList)
        }
        XCTAssertTrue(capture.isListening)
        XCTAssertTrue(capture.hasSignal)
        relay.detach(flush: true)
        relay.receive(nil, frames: 512, audio: sound.audioBufferList)
        try capture.finish()
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 251 * 512,
                       "Flushing the sink preserves every queued cycle without writing post-detach cycles")
    }

    func testTrailingQuietAccumulatesSub100msSinkCyclesSoStopClosuresDoNotSetFakeFloor() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let capture = try DictationAudioFile(url: url, format: format)
        let startupSilence = try buffer(format: format, frames: 4_800, value: 0)
        let vowel = try buffer(format: format, frames: 512, value: 0.25)
        let closure = try buffer(format: format, frames: 512, value: 0)
        let room = try buffer(format: format, frames: 512, value: 0.004)
        XCTAssertNil(capture.append(startupSilence))
        for _ in 0..<10 { XCTAssertNil(capture.append(vowel)) }
        // Two 512-frame buffers (~21 ms stop closure) surrounded by vowel frames inside
        // the next 100 ms window must not set a zero room floor or trigger trailingQuiet.
        XCTAssertNil(capture.append(closure))
        XCTAssertNil(capture.append(closure))
        for _ in 0..<8 { XCTAssertNil(capture.append(vowel)) }
        XCTAssertEqual(capture.trailingQuiet, 0)
        for _ in 0..<10 { XCTAssertNil(capture.append(room)) }
        XCTAssertGreaterThanOrEqual(capture.trailingQuiet, 0.1)
        try capture.finish()
    }

    func testDurationLimitFinalizesOnlyOnceWithoutWaitingOnAClock() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let capture = try DictationAudioFile(url: url, format: format, maximumDuration: 5.0 / 16_000)
        let chunk = try buffer(format: format, frames: 3, value: 0.5)
        XCTAssertNil(capture.append(chunk))
        XCTAssertEqual(capture.append(chunk), true)
        XCTAssertEqual(chunk.frameLength, 3, "Truncating the last write must not alter the caller's buffer")
        XCTAssertNil(capture.append(chunk))
        try capture.finish()
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 5)
    }

    func testCloseRejectsLateAudioAndSilentBuffersStillProveCaptureStarted() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let capture = try DictationAudioFile(url: url, format: format)
        let silence = try buffer(format: format, frames: 100, value: 0)
        XCTAssertNil(capture.append(silence))
        XCTAssertTrue(capture.isDeliveringAudio)
        XCTAssertEqual(capture.level, 0)
        try capture.finish()
        XCTAssertNil(capture.append(silence))
        try capture.finish()
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 100)
    }

    func testDigitalSilenceAndQuietSignalAreDistinctFromBufferArrival() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let capture = try DictationAudioFile(url: url, format: format)
        XCTAssertNil(capture.append(try buffer(format: format, frames: 100, value: 0)))
        XCTAssertTrue(capture.isDeliveringAudio)
        XCTAssertFalse(capture.hasSignal)
        XCTAssertNil(capture.append(try buffer(format: format, frames: 100, value: 0.000_000_1)))
        XCTAssertEqual(capture.level, 0, "Signal can be below the visible meter's floor")
        XCTAssertTrue(capture.hasSignal, "Even quiet nonzero audio forbids discarding a phrase on recovery")
        try capture.finish()
    }

    func testFormatChangeFailsInsteadOfReturningPartialAudioAsSuccess() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let otherFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let capture = try DictationAudioFile(url: url, format: format)
        XCTAssertNil(capture.append(try buffer(format: format, frames: 100, value: 0.2)))
        let changed = try buffer(format: otherFormat, frames: 100, value: 0.2)
        XCTAssertEqual(capture.append(changed), false)
        XCTAssertNil(capture.append(changed))
        XCTAssertThrowsError(try capture.finish())
    }

    func testRelayWritesOnlyWhileAHoldIsAttached() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let chunk = try buffer(format: format, frames: 160, value: 0.25)
        let relay = DictationTapRelay()
        let sink = try DictationAudioFile(url: url, format: format)
        relay.receive(nil, frames: 160, audio: chunk.audioBufferList)
        relay.attach(sink, ended: { _ in })
        relay.receive(nil, frames: 160, audio: chunk.audioBufferList)
        relay.detach(flush: true)
        relay.receive(nil, frames: 160, audio: chunk.audioBufferList)
        try sink.finish()
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 160)
    }

    func testNonfiniteSamplesFailBeforeWritingAudio() throws {
        for sample in [Float.nan, .infinity, -.infinity] {
            let url = temporaryFile()
            defer { try? FileManager.default.removeItem(at: url) }
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let capture = try DictationAudioFile(url: url, format: format)
            let chunk = try buffer(format: format, frames: 4, value: sample)
            XCTAssertEqual(capture.append(chunk), false)
            XCTAssertThrowsError(try capture.finish())
            XCTAssertEqual(try AVAudioFile(forReading: url).length, 0)
        }
    }

    func testRelayForwardsNativeSampleTimesToTheFileDiagnostics() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let sink = try DictationAudioFile(url: url, format: format)
        let relay = DictationTapRelay()
        relay.attach(sink, ended: { _ in })
        let chunk = try buffer(format: format, frames: 160, value: 0.5)
        var firstStamp = AudioTimeStamp()
        firstStamp.mFlags = .sampleTimeValid
        firstStamp.mSampleTime = 0
        var secondStamp = AudioTimeStamp()
        secondStamp.mFlags = .sampleTimeValid
        secondStamp.mSampleTime = 320
        relay.receive(&firstStamp, frames: 160, audio: chunk.audioBufferList)
        relay.receive(&secondStamp, frames: 160, audio: chunk.audioBufferList)
        relay.detach(flush: true)
        try sink.finish()
        XCTAssertEqual(sink.diagnostics.missingFrames, 160)
        XCTAssertEqual(sink.diagnostics.untimedBuffers, 0)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 320, "Diagnostics must not repair or trim PCM")
    }

    func testNativeWAVPreservesEveryChannelAndSampleAcrossInputRates() throws {
        for rate in [16_000.0, 24_000, 44_100, 48_000] {
            for channels: AVAudioChannelCount in [1, 2, 3] {
                let url = temporaryFile()
                defer { try? FileManager.default.removeItem(at: url) }
                let layout = try XCTUnwrap(AVAudioChannelLayout(
                    layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
                let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                                       interleaved: false, channelLayout: layout))
                let capture = try DictationAudioFile(url: url, format: format)
                let chunk = try buffer(format: format, frames: 60, value: 0)
                for channel in 0..<Int(channels) {
                    for sample in 0..<60 {
                        chunk.floatChannelData![channel][sample] = Float(sample - 30) / Float(100 * (channel + 1))
                    }
                }
                XCTAssertNil(capture.append(chunk))
                try capture.finish()
                let file = try AVAudioFile(forReading: url)
                XCTAssertEqual(file.fileFormat.sampleRate, rate)
                XCTAssertEqual(file.fileFormat.channelCount, channels)
                XCTAssertEqual(file.length, 60)
                let restored = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 60))
                try file.read(into: restored)
                XCTAssertEqual(restored.frameLength, 60)
                for channel in 0..<Int(channels) {
                    XCTAssertEqual(Array(UnsafeBufferPointer(start: restored.floatChannelData![channel], count: 60)),
                                   Array(UnsafeBufferPointer(start: chunk.floatChannelData![channel], count: 60)))
                }
            }
        }
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tlm-audio-test-\(UUID().uuidString).wav")
    }

    private func buffer(format: AVAudioFormat, frames: AVAudioFrameCount, value: Float) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) { channels[channel][frame] = value }
        }
        return buffer
    }
}

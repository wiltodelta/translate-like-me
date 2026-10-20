import AVFoundation
import Foundation
@preconcurrency import WhisperKit
import XCTest
@testable import TranslateLikeMe

final class DictationAudioFileTests: XCTestCase {
    @MainActor
    func testSilentOutputMatchesTheCaptureFormatAndRendersZerosOffTheMainActor() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let engine = AVAudioEngine()
        DictationRecorder.connectSilentOutput(to: engine, format: format)
        XCTAssertEqual(engine.outputNode.inputFormat(forBus: 0), format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 128)
        try engine.start()
        defer { engine.stop() }
        let samples = try await Task.detached { @Sendable in
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            channel.initialize(repeating: 0.5, count: 128)
            XCTAssertEqual(try engine.renderOffline(128, to: buffer), .success)
            XCTAssertEqual(buffer.frameLength, 128)
            return Array(UnsafeBufferPointer(start: channel, count: 128))
        }.value
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })
    }

    func testFinalizedNativePCMCanBeReadAsWhisperAudio() throws {
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
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        XCTAssertEqual(samples.count, 1_600)
        XCTAssertEqual(try XCTUnwrap(samples.dropFirst(100).first), 0.25, accuracy: 0.001)
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

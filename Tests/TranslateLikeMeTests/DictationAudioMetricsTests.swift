import AVFoundation
import XCTest
@testable import TranslateLikeMe

final class DictationAudioMetricsTests: XCTestCase {
    func testNativeTimelineCountsGapsAndOverlapsWithoutChangingSamples() throws {
        let buffer = try makeBuffer(channels: 1, frames: 160)
        var metrics = DictationAudioMetrics(rate: 16_000, channels: 1)
        for time: Int64 in [0, 160, 640, 720] {
            let measurement = metrics.observe(buffer, at: AVAudioTime(sampleTime: time, atRate: 16_000))
            XCTAssertTrue(measurement.valid)
            XCTAssertTrue(measurement.hasSignal)
        }
        XCTAssertEqual(metrics.frames, 640)
        XCTAssertEqual(metrics.missingFrames, 320)
        XCTAssertEqual(metrics.overlappingFrames, 80)
        XCTAssertEqual(buffer.frameLength, 160)
        XCTAssertEqual(buffer.floatChannelData?[0][0], 0.5)
    }

    func testMissingAndWrongRateTimestampsDoNotInventContinuity() throws {
        let buffer = try makeBuffer(channels: 1, frames: 160)
        var metrics = DictationAudioMetrics(rate: 16_000, channels: 1)
        _ = metrics.observe(buffer, at: AVAudioTime(sampleTime: 0, atRate: 16_000))
        _ = metrics.observe(buffer, at: nil)
        _ = metrics.observe(buffer, at: AVAudioTime(sampleTime: 100_000, atRate: 16_000))
        _ = metrics.observe(buffer, at: AVAudioTime(sampleTime: 0, atRate: 24_000))
        _ = metrics.observe(buffer, at: AVAudioTime(sampleTime: 0, atRate: 16_000))
        XCTAssertEqual(metrics.untimedBuffers, 1)
        XCTAssertEqual(metrics.invalidTimestamps, 1)
        XCTAssertEqual(metrics.missingFrames, 0)
        XCTAssertEqual(metrics.overlappingFrames, 0)
    }

    func testSummaryPreservesPerChannelLevelsAndCountsInvalidSamples() throws {
        let buffer = try makeBuffer(channels: 2, frames: 4)
        buffer.floatChannelData![0][0] = 0
        buffer.floatChannelData![0][1] = 1
        buffer.floatChannelData![0][2] = .nan
        buffer.floatChannelData![1][0] = -.infinity
        var metrics = DictationAudioMetrics(rate: 16_000, channels: 2)
        XCTAssertFalse(metrics.observe(buffer, at: nil).valid)
        XCTAssertEqual(metrics.invalidSamples, 2)
        XCTAssertTrue(metrics.summary.contains("clipped=1 invalid=2"))
        XCTAssertTrue(metrics.summary.contains("peak=[1.000000,0.500000]"))
        XCTAssertFalse(metrics.summary.lowercased().contains("nan"))
        XCTAssertEqual(buffer.floatChannelData![0][1], 1)
    }

    func testNormalizedArrayMetricsDoNotMutateAudio() {
        let samples: [Float] = [0, 0.5, -0.5, 1]
        let metrics = DictationAudioMetrics.normalized(samples)
        XCTAssertEqual(metrics.frames, 4)
        XCTAssertEqual(metrics.invalidSamples, 0)
        XCTAssertTrue(metrics.summary.contains("rms=[0.612372]"))
        XCTAssertTrue(metrics.summary.contains("zeros=1 clipped=1"))
        XCTAssertEqual(samples, [0, 0.5, -0.5, 1])
    }

    func testSignalThresholdPreservesTheStrictAbsoluteSampleBoundary() {
        let threshold: Float = 0.00001
        let cases: [([Float], Bool)] = [([], false), ([0], false), ([threshold], false), ([-threshold], false),
            ([threshold.nextDown], false), ([threshold.nextUp], true), ([-threshold.nextUp], true),
            ([0, -threshold.nextUp, 0], true)]
        for (samples, expected) in cases {
            let metrics = DictationAudioMetrics.normalized(samples)
            XCTAssertEqual(metrics.hasSignal(above: threshold), expected)
        }
    }

    private func makeBuffer(channels: AVAudioChannelCount, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: channels))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for sample in 0..<Int(frames) { buffer.floatChannelData![channel][sample] = 0.5 }
        }
        return buffer
    }
}

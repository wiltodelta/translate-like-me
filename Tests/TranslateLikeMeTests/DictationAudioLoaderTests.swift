import AVFoundation
import XCTest
@testable import TranslateLikeMe

final class DictationAudioLoaderTests: XCTestCase {
    func testFiniteConversionPreservesTheWholeNativeDuration() throws {
        for rate in [8_000.0, 16_000, 24_000, 44_100, 48_000, 96_000, 192_000] {
            let url = try fixture(rate: rate, channels: 1) { frame, _ in
                Float(0.2 * sin(2 * .pi * 437 * Double(frame) / rate))
            }
            defer { try? FileManager.default.removeItem(at: url) }
            let samples = try DictationAudioLoader.load(url)
            XCTAssertEqual(samples.count, 20_000, "Truncated finite input at \(rate) Hz")
            XCTAssertTrue(samples.allSatisfy(\.isFinite))
        }
    }

    func testOppositePhaseInputChannelsDoNotEraseSpeech() throws {
        let url = try fixture(rate: 16_000, channels: 2) { frame, channel in
            Float(0.2 * sin(2 * .pi * 437 * Double(frame) / 16_000)) * (channel == 0 ? 1 : -1)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try DictationAudioLoader.load(url)
        XCTAssertEqual(samples.count, 20_000)
        XCTAssertGreaterThan(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count), 0.01)
    }

    func testActiveChannelIsNotDilutedBySilentOrDCChannels() throws {
        let url = try fixture(rate: 48_000, channels: 3) { frame, channel in
            switch channel {
            case 0: 0
            case 1: 0.4
            default: Float(0.2 * sin(2 * .pi * 437 * Double(frame) / 48_000))
            }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try DictationAudioLoader.load(url)
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        XCTAssertEqual(samples.count, 20_000)
        XCTAssertEqual(mean, 0, accuracy: 0.001)
        // The abrupt file boundary has converter ringing; test the steady tone.
        let interior = samples.dropFirst(512).dropLast(512)
        XCTAssertEqual(interior.map { abs($0) }.max() ?? 0, 0.2, accuracy: 0.002)
    }

    func testChannelSelectionStaysFixedForTheEntireUtterance() throws {
        let url = try fixture(rate: 16_000, channels: 2) { frame, channel in
            let gain: Float = channel == 0 ? (frame < 10_000 ? 0.3 : 0.1) : 0.2
            return gain * Float(sin(2 * .pi * 437 * Double(frame) / 16_000))
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try DictationAudioLoader.load(url)
        let file = try AVAudioFile(forReading: url)
        let native = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 20_000))
        try file.read(into: native)
        XCTAssertEqual(samples, Array(UnsafeBufferPointer(start: native.floatChannelData![0], count: 20_000)))
    }

    func testFractionalDurationsDrainWithoutInventingExtraAudio() throws {
        for rate in [24_000.0, 44_100, 48_000, 96_000, 192_000] {
            for frames in [1, 17, 129, 513, 32_769] {
                let url = try fixture(rate: rate, channels: 1, frames: frames) { _, _ in 0.25 }
                defer { try? FileManager.default.removeItem(at: url) }
                let samples = try DictationAudioLoader.load(url)
                XCTAssertLessThanOrEqual(abs(Double(samples.count) - Double(frames) * 16_000 / rate), 1)
                XCTAssertTrue(samples.allSatisfy(\.isFinite))
            }
        }
    }

    func testHighRateInputsKeepTheirInBandAmplitude() throws {
        for rate in [96_000.0, 192_000] {
            let url = try fixture(rate: rate, channels: 1) { frame, _ in
                Float(0.2 * sin(2 * .pi * 437 * Double(frame) / rate))
            }
            defer { try? FileManager.default.removeItem(at: url) }
            let samples = try DictationAudioLoader.load(url)
            XCTAssertEqual(samples.dropFirst(800).dropLast(800).map { abs($0) }.max() ?? 0, 0.2, accuracy: 0.002)
        }
    }

    func testEmptyInputRemainsEmpty() throws {
        let url = try fixture(rate: 48_000, channels: 1, frames: 0) { _, _ in 0 }
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try DictationAudioLoader.load(url), [])
    }

    private func fixture(rate: Double, channels: AVAudioChannelCount, frames: Int? = nil,
                         sample: (Int, Int) -> Float) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tlm-loader-\(UUID().uuidString).wav")
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                               interleaved: false, channelLayout: layout))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: max(1, AVAudioFrameCount(frames ?? Int(rate * 1.25)))))
        buffer.frameLength = AVAudioFrameCount(frames ?? Int(rate * 1.25))
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = sample(frame, channel)
            }
        }
        do {
            let writer = try DictationAudioFile(url: url, format: format)
            XCTAssertNil(writer.append(buffer))
            try writer.finish()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }
}

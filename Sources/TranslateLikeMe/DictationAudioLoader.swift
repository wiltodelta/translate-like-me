import AVFoundation
import Foundation
import os

// Own the finite-file and microphone-channel contract before either recognizer.
enum DictationAudioLoader {
    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate > 0, file.processingFormat.channelCount > 0 else {
            throw DictationError.microphone
        }
        guard file.length > 0 else { return [] }
        let source = try buffer(format: file.processingFormat, capacity: 32_768)
        let channel = try strongestChannel(file, buffer: source)
        file.framePosition = 0
        Logger.app("dictation").notice("""
            Dictation channel conversion: channels=\(file.processingFormat.channelCount) selectedChannel=\(channel) \
            sourceRate=\(file.processingFormat.sampleRate) sourceFrames=\(file.length)
            """)
        return try convert(file, source: source, channel: channel)
    }

    // Keep one channel for the entire utterance. Summation can cancel opposite
    // phases; per-buffer selection can switch phase halfway through a word.
    // Remove the DC contribution from the energy score, without modifying PCM.
    private static func strongestChannel(_ file: AVAudioFile, buffer: AVAudioPCMBuffer) throws -> Int {
        let count = Int(file.processingFormat.channelCount)
        guard count > 1 else { return 0 }
        var sums = Array(repeating: 0.0, count: count)
        var squares = sums
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw DictationError.microphone
            }
            for channel in 0..<count {
                for frame in 0..<Int(buffer.frameLength) {
                    let value = Double(channels[channel][frame])
                    guard value.isFinite else { throw DictationError.microphone }
                    sums[channel] += value
                    squares[channel] += value * value
                }
            }
        }
        let scores = (0..<count).map { max(0, squares[$0] - sums[$0] * sums[$0] / Double(file.length)) }
        return scores.indices.reduce(0) { scores[$1] > scores[$0] ? $1 : $0 }
    }

    private static func convert(_ file: AVAudioFile, source: AVAudioPCMBuffer, channel: Int) throws -> [Float] {
        let converter = try converter(rate: file.processingFormat.sampleRate)
        let input = try buffer(format: converter.inputFormat, capacity: source.frameCapacity)
        let output = try buffer(format: converter.outputFormat, capacity: 4_096)
        let estimate = Double(file.length) * 16_000 / file.processingFormat.sampleRate
        guard estimate.isFinite, estimate < Double(Int.max - 4_096) else { throw DictationError.microphone }
        let expected = Int(estimate.rounded())
        var samples: [Float] = []
        samples.reserveCapacity(expected)
        var readFailure: Error?
        while true {
            try Task.checkCancellation()
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, inputStatus in
                guard file.framePosition < file.length, readFailure == nil else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try read(file, source: source, mono: input, channel: channel, requested: requested)
                    inputStatus.pointee = .haveData
                    return input
                } catch {
                    readFailure = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let readFailure { throw readFailure }
            if let error { throw error }
            guard status != .error, let data = output.floatChannelData else { throw DictationError.microphone }
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            guard samples.count <= expected + 4_096 else { throw DictationError.microphone }
            if status == .endOfStream { break }
            guard output.frameLength > 0 else { throw DictationError.microphone }
        }
        return try validated(samples, expected: expected)
    }

    private static func validated(_ samples: [Float], expected: Int) throws -> [Float] {
        // Conversion may round a fractional output frame in either direction.
        // Never pad over a missing tail or discard a substantial excess.
        guard abs(samples.count - expected) <= 1 else { throw DictationError.microphone }
        var result = samples
        if result.count > expected { result.removeLast(result.count - expected) }
        return result
    }

    private static func read(_ file: AVAudioFile, source: AVAudioPCMBuffer, mono: AVAudioPCMBuffer,
                             channel: Int, requested: AVAudioPacketCount) throws {
        try file.read(into: source, frameCount: max(1, min(requested, source.frameCapacity)))
        guard source.frameLength > 0, let data = source.floatChannelData else { throw DictationError.microphone }
        let values = UnsafeBufferPointer(start: data[channel], count: Int(source.frameLength))
        guard values.allSatisfy(\.isFinite) else { throw DictationError.microphone }
        mono.frameLength = source.frameLength
        mono.floatChannelData![0].update(from: data[channel], count: Int(source.frameLength))
    }

    private static func converter(rate: Double) throws -> AVAudioConverter {
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let result = AVAudioConverter(from: mono, to: target) else { throw DictationError.microphone }
        // Retain the measured legacy filter at microphone rates. Its default
        // quality attenuated in-band signals at 96/192 kHz, so use maximum there.
        result.sampleRateConverterQuality = rate > 48_000 ? AVAudioQuality.max.rawValue : AVAudioQuality.medium.rawValue
        result.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        return result
    }

    private static func buffer(format: AVAudioFormat, capacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw DictationError.microphone
        }
        return result
    }
}

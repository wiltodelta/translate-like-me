import AVFoundation
import Foundation

// Aggregate numbers only. Never retains samples, device names or recognized text.
struct DictationAudioMetrics {
    struct Measurement {
        let level: Double
        let hasSignal: Bool
        let valid: Bool
    }
    let rate: Double
    private(set) var frames: Int64 = 0
    private(set) var invalidSamples = 0
    private(set) var missingFrames: Int64 = 0
    private(set) var overlappingFrames: Int64 = 0
    private(set) var untimedBuffers = 0
    private(set) var invalidTimestamps = 0
    private var expectedTime: Int64?
    private var energy: [Double]
    private var peaks: [Double]
    private var zeros = 0
    private var clipped = 0

    init(rate: Double, channels: Int) {
        self.rate = rate
        energy = Array(repeating: 0, count: channels)
        peaks = Array(repeating: 0, count: channels)
    }

    mutating func observe(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) -> Measurement {
        guard Int(buffer.format.channelCount) == energy.count,
              let channels = buffer.floatChannelData else {
            return Measurement(level: 0, hasSignal: false, valid: false)
        }
        let oldInvalid = invalidSamples
        var bufferEnergy: Double = 0
        for channel in energy.indices {
            bufferEnergy += observe(UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)),
                                    channel: channel)
        }
        frames += Int64(buffer.frameLength)
        observeTime(time, frames: Int64(buffer.frameLength))
        let mean = bufferEnergy / Double(max(1, Int(buffer.frameLength) * energy.count))
        let level = min(1, max(0, (10 * log10(max(mean, 1e-12)) + 60) / 60))
        return Measurement(level: level, hasSignal: bufferEnergy > 0, valid: invalidSamples == oldInvalid)
    }

    private mutating func observe(_ samples: UnsafeBufferPointer<Float>, channel: Int) -> Double {
        var sum: Double = 0
        for value in samples {
            guard value.isFinite else { invalidSamples += 1; continue }
            let sample = Double(value)
            sum += sample * sample
            peaks[channel] = max(peaks[channel], abs(sample))
            if sample == 0 { zeros += 1 }
            if abs(sample) >= 1 { clipped += 1 }
        }
        energy[channel] += sum
        return sum
    }

    private mutating func observeTime(_ time: AVAudioTime?, frames: Int64) {
        guard let time, time.isSampleTimeValid else {
            untimedBuffers += 1
            expectedTime = nil
            return
        }
        let next = time.sampleTime.addingReportingOverflow(frames)
        guard time.sampleRate == rate, !next.overflow else {
            invalidTimestamps += 1
            expectedTime = nil
            return
        }
        if let expectedTime {
            let delta = time.sampleTime.subtractingReportingOverflow(expectedTime)
            if delta.overflow || delta.partialValue == Int64.min {
                invalidTimestamps += 1
            } else if delta.partialValue > 0 {
                let total = missingFrames.addingReportingOverflow(delta.partialValue)
                missingFrames = total.overflow ? .max : total.partialValue
            } else if delta.partialValue < 0 {
                let total = overlappingFrames.subtractingReportingOverflow(delta.partialValue)
                overlappingFrames = total.overflow ? .max : total.partialValue
            }
        }
        expectedTime = next.partialValue
    }

    var summary: String {
        let rms = energy.map { String(format: "%.6f", sqrt($0 / Double(max(1, frames)))) }.joined(separator: ",")
        let peak = peaks.map { String(format: "%.6f", $0) }.joined(separator: ",")
        return "rate=\(rate) channels=\(energy.count) frames=\(frames) rms=[\(rms)] peak=[\(peak)] " +
            "zeros=\(zeros) clipped=\(clipped) invalid=\(invalidSamples) gaps=\(missingFrames) " +
            "overlaps=\(overlappingFrames) untimed=\(untimedBuffers) badTimes=\(invalidTimestamps)"
    }

    func hasSignal(above threshold: Float) -> Bool {
        frames > 0 && peaks.contains { $0 > Double(threshold) }
    }

    static func normalized(_ samples: [Float]) -> Self {
        var metrics = Self(rate: 16_000, channels: 1)
        samples.withUnsafeBufferPointer { _ = metrics.observe($0, channel: 0) }
        metrics.frames = Int64(samples.count)
        return metrics
    }
}

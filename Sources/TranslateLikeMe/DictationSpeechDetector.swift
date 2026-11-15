@preconcurrency import CoreML
import Foundation

// Silero v6.2.1's pinned Core ML schema uses 4096 fresh samples plus 64
// context samples. Locate outer speech bounds with 400 ms collars while keeping
// internal pauses intact. Owned and called only by DictationEngine's actor.
struct DictationSpeechDetector {
    static let collarSamples = 6_400
    private let model: MLModel

    init(directory: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: directory, configuration: configuration)
    }

    func speechBounds(in samples: [Float]) throws -> Range<Int>? {
        guard !samples.isEmpty else { return nil }
        let audio = try MLMultiArray(shape: [1, 4160], dataType: .float32)
        var hidden = try MLMultiArray(shape: [1, 128], dataType: .float32)
        var cell = try MLMultiArray(shape: [1, 128], dataType: .float32)
        for state in [hidden, cell] {
            let values = state.dataPointer.assumingMemoryBound(to: Float.self)
            for index in 0..<128 { values[index] = 0 }
        }
        let values = audio.dataPointer.assumingMemoryBound(to: Float.self)
        var firstSpeech: Int?
        var lastSpeechEnd = 0
        for start in stride(from: 0, to: samples.count, by: 4096) {
            try Task.checkCancellation()
            for index in 0..<64 { values[index] = start >= 64 ? samples[start - 64 + index] : 0 }
            for index in 0..<4096 {
                values[64 + index] = start + index < samples.count ? samples[start + index] : 0
            }
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input": audio, "hidden_state": hidden, "cell_state": cell
            ])
            let output = try model.prediction(from: input)
            guard let probability = output.featureValue(for: "vad_output")?.multiArrayValue?[0].floatValue,
                  probability.isFinite,
                  let nextHidden = output.featureValue(for: "new_hidden_state")?.multiArrayValue,
                  let nextCell = output.featureValue(for: "new_cell_state")?.multiArrayValue else {
                throw DictationError.notReady
            }
            if probability >= 0.5 {
                if firstSpeech == nil { firstSpeech = start }
                lastSpeechEnd = min(samples.count, start + 4096)
            }
            hidden = nextHidden
            cell = nextCell
        }
        guard let firstSpeech else { return nil }
        return max(0, firstSpeech - Self.collarSamples)..<min(samples.count, lastSpeechEnd + Self.collarSamples)
    }
}

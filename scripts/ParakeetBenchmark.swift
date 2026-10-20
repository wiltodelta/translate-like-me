// Experimental entry point, generated package and shared scoring: benchmark-parakeet.py.
import CryptoKit
import FluidAudio
import Foundation
@preconcurrency import WhisperKit

@main
struct ParakeetBenchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 7, args[1] != "ultra" {
            try await DictationBenchmark.main()
            return
        }
        guard args.count == 7, args[1] == "ultra", let repetitions = Int(args[5]), repetitions > 0 else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        AppLogger.minimumLevel = .error
        AppLogger.mirrorsToConsole = false
        let output = URL(fileURLWithPath: args[6])
        let examples = try JSONDecoder().decode([DictationBenchmark.Example].self,
            from: Data(contentsOf: URL(fileURLWithPath: args[4])))
        let start = ContinuousClock.now
        let models = try AsrModels.loadLocal(from: URL(fileURLWithPath: args[2]), version: .ultra)
        let manager = AsrManager(models: models)
        var report: [String: Any] = ["model": "ultra", "arm": "ane", "loadSeconds": DictationBenchmark.seconds(start)]
        var rows: [[String: Any]] = []
        try DictationBenchmark.write(report, to: output)
        let detector = try DictationSpeechDetector(directory: URL(fileURLWithPath: args[3])
            .appendingPathComponent("models/FluidInference/silero-vad-coreml/" + DictationEngine.detectorModel))
        for iteration in 0...repetitions {
            for offset in examples.indices {
                let example = examples[(offset + iteration) % examples.count]
                let started = ContinuousClock.now
                let cpu = try DictationBenchmark.cpuSeconds()
                // Use the same loader, speech gate and quiet tail as the Whisper arm.
                var samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: example.file)
                let duration = Double(samples.count) / 16_000
                let audioLoad = DictationBenchmark.seconds(started)
                let vad = ContinuousClock.now
                let speech = try samples.contains { abs($0) > 0.00001 } && detector.containsSpeech(samples)
                let vadTime = DictationBenchmark.seconds(vad)
                if samples.count < 16_000 { samples += Array(repeating: 0, count: 16_000 - samples.count) }
                samples += Array(repeating: 0, count: 8_000)
                let inference = ContinuousClock.now
                var state = try TdtDecoderState()
                let text = speech ? try await manager.transcribe(samples, decoderState: &state).text : ""
                let inferenceTime = DictationBenchmark.seconds(inference)
                let normalized = DictationBenchmark.normalized(text)
                let missing = example.terms.filter { term in
                    let expected = DictationBenchmark.normalized(example.expected)
                        .components(separatedBy: DictationBenchmark.normalized(term)).count - 1
                    let actual = normalized.components(separatedBy: DictationBenchmark.normalized(term)).count - 1
                    return actual < max(1, expected)
                }
                rows.append(["case": example.id, "iteration": iteration, "audioSeconds": duration,
                    "totalSeconds": DictationBenchmark.seconds(started),
                    "cpuSeconds": try DictationBenchmark.cpuSeconds() - cpu,
                    "audioLoadSeconds": audioLoad, "vadSeconds": vadTime, "speech": speech,
                    "inferenceSeconds": inferenceTime, "missingTerms": missing, "empty": text.isEmpty,
                    "textHash": SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
                    "normalizedHash": SHA256.hash(data: Data(normalized.utf8))
                        .map { String(format: "%02x", $0) }.joined(),
                    "wordErrors": DictationBenchmark.wordErrors(expected: example.expected, actual: text),
                    "referenceWords": DictationBenchmark.normalized(example.expected).split(separator: " ").count,
                    "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                    "footprint": DictationBenchmark.footprint() as Any? ?? NSNull()])
                report["rows"] = rows
                try DictationBenchmark.write(report, to: output)
            }
        }
        await manager.cleanup()
    }
}

// Compile with the release WhisperKit objects and the production dictation
// sources; see docs/dictation-model-efficiency.md. Never opens a microphone.
import CryptoKit
import Darwin
import Foundation
@preconcurrency import WhisperKit

@main
struct DictationBenchmark {
    struct Example: Decodable {
        let id: String
        let file: String
        let terms: [String]
        let expected: String
    }

    static func seconds(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static func cpuSeconds() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw CocoaError(.fileReadUnknown) }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    static func write(_ report: [String: Any], to output: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output, options: .atomic)
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: #"[\W_]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func wordErrors(expected: String, actual: String) -> Int {
        let reference = normalized(expected).split(separator: " ")
        let hypothesis = normalized(actual).split(separator: " ")
        var previous = Array(0...hypothesis.count)
        for (index, word) in reference.enumerated() {
            var current = [index + 1]
            for (column, candidate) in hypothesis.enumerated() {
                current.append(min(current[column] + 1, previous[column + 1] + 1,
                                   previous[column] + (word == candidate ? 0 : 1)))
            }
            previous = current
        }
        return previous[hypothesis.count]
    }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 7, let model = DictationModel(rawValue: args[1]),
              let repetitions = Int(args[5]), repetitions > 0 else {
            fatalError("Usage: benchmark <small|turbo|largeV3> <arm> <cache> <cases.json> <repetitions> <output.json>")
        }
        let arm = args[2]
        let cache = URL(fileURLWithPath: args[3])
        let output = URL(fileURLWithPath: args[6])
        let examples = try JSONDecoder().decode([Example].self, from: Data(contentsOf:
            URL(fileURLWithPath: args[4])))
        guard !examples.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        var report: [String: Any] = ["model": model.rawValue, "variant": model.variant, "arm": arm,
                                    "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                    "initialFootprint": footprint() as Any? ?? NSNull()]
        var rows: [[String: Any]] = []
        try write(report, to: output)
        if arm == "prepare" {
            let engine = DictationEngine(directory: cache)
            for iteration in 0..<repetitions {
                let start = ContinuousClock.now
                try await engine.prepare(model: model, download: false) { _ in }
                guard await engine.loadedModel == model else { throw DictationError.notReady }
                rows.append(["iteration": iteration, "prepareSeconds": seconds(start),
                             "footprint": footprint() as Any? ?? NSNull()])
                await engine.unload()
                report["rows"] = rows
                try write(report, to: output)
            }
            return
        }
        let units: ModelComputeOptions
        switch arm {
        case "gpu": units = ModelComputeOptions(audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU)
        case "ane", "ane-prewarm", "ane-no-fallback", "ane-vad": units = ModelComputeOptions()
        case "all": units = ModelComputeOptions(audioEncoderCompute: .all, textDecoderCompute: .all)
        case "ane-gpu":
            units = ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndGPU)
        case "gpu-ane":
            units = ModelComputeOptions(audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndNeuralEngine)
        default: fatalError("Unknown benchmark arm")
        }
        guard let tokenizer = model.tokenizer else { throw DictationError.notReady }
        let start = ContinuousClock.now
        let kit = try await WhisperKit(WhisperKitConfig(
            modelFolder: cache.appendingPathComponent("models/argmaxinc/whisperkit-coreml/" + model.variant).path,
            tokenizerFolder: cache.appendingPathComponent("models/" + tokenizer.repository),
            computeOptions: units, verbose: false, logLevel: .none,
            prewarm: arm == "ane-prewarm", load: true, download: false))
        report["loadSeconds"] = seconds(start)
        report["loadedFootprint"] = footprint() as Any? ?? NSNull()
        report["loadTimings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(kit.currentTimings))
        let detector = try DictationSpeechDetector(directory: cache.appendingPathComponent(
            "models/FluidInference/silero-vad-coreml/" + DictationEngine.detectorModel))
        for iteration in 0...repetitions {
            // Rotate case order; iteration zero is the first inference pass, kept
            // separate from warm timings. Each arm runs in its own process.
            for offset in examples.indices {
                let example = examples[(offset + iteration) % examples.count]
                let started = ContinuousClock.now
                let cpuStart = try cpuSeconds()
                var samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: example.file)
                let audioSeconds = Double(samples.count) / 16_000
                let loadedAudio = seconds(started)
                let hasSignal = samples.contains { abs($0) > 0.00001 }
                let vadStart = ContinuousClock.now
                let speech = try hasSignal && detector.containsSpeech(samples)
                let vadSeconds = seconds(vadStart)
                if samples.count < 16_000 { samples += Array(repeating: 0, count: 16_000 - samples.count) }
                samples += Array(repeating: 0, count: 8_000)
                var options = DecodingOptions(task: .transcribe, language: nil,
                                              detectLanguage: true, skipSpecialTokens: true)
                if arm == "ane-no-fallback" { options.temperatureFallbackCount = 0 }
                if arm == "ane-vad" { options.chunkingStrategy = .vad; options.concurrentWorkerCount = 2 }
                let inference = ContinuousClock.now
                let results = speech ? try await kit.transcribe(audioArray: samples, decodeOptions: options) : []
                let inferenceSeconds = seconds(inference)
                let text = DictationEngine.transcript(from: results)
                let totalSeconds = seconds(started)
                let cpuUsed = try cpuSeconds() - cpuStart
                let missing = example.terms.filter { term in
                    let expected = normalized(example.expected).components(separatedBy: normalized(term)).count - 1
                    let actual = normalized(text).components(separatedBy: normalized(term)).count - 1
                    return actual < max(1, expected)
                }
                let textHash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                let normalizedHash = SHA256.hash(data: Data(normalized(text).utf8))
                    .map { String(format: "%02x", $0) }.joined()
                rows.append(["case": example.id, "iteration": iteration, "audioSeconds": audioSeconds,
                             "totalSeconds": totalSeconds, "cpuSeconds": cpuUsed,
                             "audioLoadSeconds": loadedAudio, "vadSeconds": vadSeconds,
                             "inferenceSeconds": inferenceSeconds, "speech": speech,
                             "textHash": textHash, "missingTerms": missing, "empty": text.isEmpty,
                             "normalizedHash": normalizedHash,
                             "wordErrors": wordErrors(expected: example.expected, actual: text),
                             "referenceWords": normalized(example.expected).split(separator: " ").count,
                             "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                             "footprint": footprint() as Any? ?? NSNull(),
                             "timings": try results.map {
                                 try JSONSerialization.jsonObject(with: JSONEncoder().encode($0.timings))
                             }])
                report["rows"] = rows
                try write(report, to: output)
            }
        }
        await kit.unloadModels()
        report["unloadedFootprint"] = footprint() as Any? ?? NSNull()
        try write(report, to: output)
    }
}

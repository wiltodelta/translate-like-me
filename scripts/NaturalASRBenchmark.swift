// Public-recording benchmark only. Never opens the microphone.
import AVFoundation
import FluidAudio
import Foundation
@preconcurrency import WhisperKit

@main
struct NaturalASRBenchmark {
    struct Example: Codable {
        let id: String
        var file: String
        let expected: String
        let group: String
        var audioSeconds: Double?
        var speech: Bool?
        var preprocessingSeconds: Double?
    }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6 else { throw CocoaError(.fileReadInvalidFileName) }
        AppLogger.minimumLevel = .error
        AppLogger.mirrorsToConsole = false
        let cache = URL(fileURLWithPath: args[2])
        var cases = try JSONDecoder().decode([Example].self,
            from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        let destination = URL(fileURLWithPath: args[5])
        if args[1] == "export" {
            let detector = try DictationSpeechDetector(directory: cache.appendingPathComponent(
                "models/FluidInference/silero-vad-coreml/" + DictationEngine.detectorModel))
            for index in cases.indices {
                let started = ContinuousClock.now
                var samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: cases[index].file)
                cases[index].audioSeconds = Double(samples.count) / 16_000
                cases[index].speech = try samples.contains { abs($0) > 0.00001 } && detector.containsSpeech(samples)
                if samples.count < 16_000 { samples += Array(repeating: 0, count: 16_000 - samples.count) }
                samples += Array(repeating: 0, count: 8_000)
                let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
                buffer.frameLength = buffer.frameCapacity
                samples.withUnsafeBufferPointer { source in
                    buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
                }
                let file = destination.deletingLastPathComponent().appendingPathComponent(cases[index].id + ".wav")
                do {
                    let output = try AVAudioFile(forWriting: file, settings: format.settings)
                    try output.write(from: buffer)
                }
                cases[index].file = file.path
                cases[index].preprocessingSeconds = DictationBenchmark.seconds(started)
            }
            try JSONEncoder().encode(cases).write(to: destination, options: .atomic)
            return
        }
        let started = ContinuousClock.now
        var kit: WhisperKit?
        var manager: AsrManager?
        if args[1] == "ultra" {
            manager = try AsrManager(models: AsrModels.loadLocal(from: URL(fileURLWithPath: args[4]), version: .ultra))
        } else {
            guard let model = DictationModel(rawValue: args[1]) else {
                throw DictationError.notReady
            }
            guard let tokenizer = model.tokenizer else { throw DictationError.notReady }
            kit = try await WhisperKit(WhisperKitConfig(
                modelFolder: cache.appendingPathComponent("models/argmaxinc/whisperkit-coreml/" + model.variant).path,
                tokenizerFolder: cache.appendingPathComponent("models/" + tokenizer.repository),
                computeOptions: ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine), verbose: false, logLevel: .none,
                prewarm: false, load: true, download: false))
        }
        var report: [String: Any] = ["model": args[1], "loadSeconds": DictationBenchmark.seconds(started)]
        var rows: [[String: Any]] = []
        // A separate calibration clip warms each runtime; it is never scored.
        for example in cases {
            let began = ContinuousClock.now
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: example.file)
            let audioLoad = DictationBenchmark.seconds(began)
            let inference = ContinuousClock.now
            var text = ""
            if example.speech == true {
                if let manager {
                    var state = try TdtDecoderState()
                    text = try await manager.transcribe(samples, decoderState: &state).text
                } else if let kit {
                    text = DictationEngine.transcript(from: try await kit.transcribe(audioArray: samples,
                        decodeOptions: DecodingOptions(task: .transcribe, language: nil,
                            detectLanguage: true, skipSpecialTokens: true)))
                }
            }
            rows.append(["case": example.id, "text": text, "audioLoadSeconds": audioLoad,
                "inferenceSeconds": DictationBenchmark.seconds(inference),
                "totalSeconds": DictationBenchmark.seconds(began),
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                "footprint": DictationBenchmark.footprint() as Any? ?? NSNull()])
            report["rows"] = rows
            try DictationBenchmark.write(report, to: destination)
        }
        await kit?.unloadModels()
        await manager?.cleanup()
    }
}

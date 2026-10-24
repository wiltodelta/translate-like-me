import AVFoundation
import Foundation
@preconcurrency import WhisperKit
import XCTest
@testable import TranslateLikeMe

final class DictationPipelineComparisonTests: XCTestCase {
    private struct Example: Decodable, Sendable {
        let id: String
        let file: String
        let reference: String
        let channel: Int
        let unchangedInput: Bool
    }

    func testPairedSyntheticPipelineComparison() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TLM_PIPELINE_COMPARISON"] else {
            throw XCTSkip("Run scripts/check-dictation-pipeline.py for the explicit synthetic comparison")
        }
        try DictationQwenTestSupport.configure()
        let root = URL(fileURLWithPath: directory)
        let examples = try JSONDecoder().decode([Example].self,
            from: Data(contentsOf: root.appendingPathComponent("cases.json")))
        for example in examples { try Self.capture(example, root: root) }
        let report = root.appendingPathComponent("comparison.json")
        var rows = FileManager.default.fileExists(atPath: report.path)
            ? try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [[String: Any]]) : []
        try JSONEncoder().encode(DictationModel.allCases.map(\.rawValue))
            .write(to: root.appendingPathComponent("models.json"))
        for model in DictationModel.allCases {
            for arm in ["baseline", "channelOnly", "converterOnly", "candidate"] {
                if rows.filter({ $0["model"] as? String == model.rawValue && $0["arm"] as? String == arm }).count
                    == examples.count * 3 { continue }
                let engine = Self.engine(root: root, examples: examples, arm: arm)
                try stage(root, model: model, arm: arm, state: "preparing")
                try await engine.prepare(model: model, download: false) { _ in }
                try stage(root, model: model, arm: arm, state: "recognizing")
                for example in examples {
                    let url = root.appendingPathComponent(example.id + ".wav")
                    if example.unchangedInput {
                        XCTAssertEqual(try DictationAudioLoader.load(url),
                                       try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path))
                    }
                    for repetition in 1...3 {
                        if rows.contains(where: {
                            $0["model"] as? String == model.rawValue && $0["arm"] as? String == arm &&
                                $0["id"] as? String == example.id && $0["repetition"] as? Int == repetition
                        }) { continue }
                        var row: [String: Any] = ["model": model.rawValue, "arm": arm, "id": example.id,
                                                 "repetition": repetition, "reference": example.reference]
                        do {
                            row["text"] = try await engine.transcribe(url)
                            row["status"] = "recognized"
                        } catch {
                            row["text"] = ""
                            row["status"] = String(describing: error)
                        }
                        rows.append(row)
                        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                            .write(to: root.appendingPathComponent("comparison.json"), options: .atomic)
                    }
                }
                await engine.unload()
            }
        }
        XCTAssertEqual(rows.count, examples.count * DictationModel.allCases.count * 4 * 3)
    }

    private static func engine(root: URL, examples: [Example], arm: String) -> DictationEngine {
        DictationEngine(directory: root.appendingPathComponent("models"),
            languageIdentifiers: { ["ru", "en"] }, loadAudio: { url in
                let example = try XCTUnwrap(examples.first {
                    $0.id == url.deletingPathExtension().lastPathComponent
                })
                return try DictationPipelineComparisonTests.load(url, example: example, arm: arm, root: root)
            })
    }

    private static func capture(_ example: Example, root: URL) throws {
        XCTAssertEqual(example.file, URL(fileURLWithPath: example.file).lastPathComponent)
        let target = root.appendingPathComponent(example.id + ".wav")
        let receipt = root.appendingPathComponent("captured-\(example.id).json")
        if FileManager.default.fileExists(atPath: receipt.path) { return }
        let input = try AVAudioFile(forReading: root.appendingPathComponent(example.file),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 1_024))
        let sink = try DictationAudioFile(url: target, format: input.processingFormat)
        while input.framePosition < input.length {
            try input.read(into: buffer)
            XCTAssertNil(sink.append(buffer))
        }
        try sink.finish()
        try JSONEncoder().encode(["frames": input.length])
            .write(to: receipt, options: .atomic)
    }

    private func stage(_ root: URL, model: DictationModel, arm: String, state: String) throws {
        try JSONEncoder().encode(["model": model.rawValue, "arm": arm, "state": state])
            .write(to: root.appendingPathComponent("stage.json"), options: .atomic)
    }

    private static func load(_ url: URL, example: Example, arm: String, root: URL) throws -> [Float] {
        switch arm {
        case "baseline":
            return try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        case "channelOnly":
            return try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path,
                channelMode: .specificChannel(example.channel))
        case "converterOnly":
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                       frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let mono = try XCTUnwrap(AudioProcessor.convertToMono(buffer, mode: .sumChannels(nil)))
            let mixed = root.appendingPathComponent("mixed-\(example.id).wav")
            do {
                let output = try AVAudioFile(forWriting: mixed, settings: mono.format.settings)
                try output.write(from: mono)
            }
            return try DictationAudioLoader.load(mixed)
        default:
            return try DictationAudioLoader.load(url)
        }
    }
}

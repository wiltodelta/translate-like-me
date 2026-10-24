import Darwin
import Foundation
@preconcurrency import WhisperKit
import XCTest
@testable import TranslateLikeMe

final class DictationIntegrationTests: XCTestCase {
    private struct Example: Decodable {
        let file: String
        let expected: String
        let terms: [String]
    }

    func testModelSelectionLoadsTheChosenFoldersAndRecognizesSyntheticSpeech() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TLM_DICTATION_MODEL_SAMPLES"] else {
            throw XCTSkip("Set TLM_DICTATION_MODEL_SAMPLES to synthetic bilingual cases to verify every model")
        }
        let root = URL(fileURLWithPath: directory)
        let examples = try JSONDecoder().decode([Example].self,
            from: Data(contentsOf: root.appendingPathComponent("cases.json")))
        XCTAssertFalse(examples.isEmpty)
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.wiltodelta.translatelikeme.dev/Dictation")
        let engine = DictationEngine(directory: cache)
        try DictationQwenTestSupport.configure()
        for model in [DictationModel.turbo, .qwen3ASR, .turbo] {
            try await engine.prepare(model: model, download: true) { _ in }
            let loaded = await engine.loadedModel
            XCTAssertEqual(loaded, model, "Check the loaded runtime, not just selected preferences")
            for example in examples {
                let text = try await engine.transcribe(URL(fileURLWithPath: example.file))
                for term in example.terms {
                    XCTAssertTrue(text.localizedCaseInsensitiveContains(term), "Expected \(term); got \(text)")
                }
            }
        }
        await engine.unload()
        for model in DictationModel.allCases {
            try await engine.prepare(model: model, download: false) { _ in }
            let loaded = await engine.loadedModel
            XCTAssertEqual(loaded, model)
        }
        await engine.unload()
    }

    // Explicit opt-in: synthetic audio only. Normal test runs never download
    // weights, request microphone access, or infer against personal recordings.
    func testLocalModelRecognizesSyntheticLanguagesAndReloadsFromCache() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TLM_DICTATION_SAMPLES"] else {
            throw XCTSkip("Set TLM_DICTATION_SAMPLES to a synthetic cases.json directory to run local ASR")
        }
        let root = URL(fileURLWithPath: directory)
        let data = try Data(contentsOf: root.appendingPathComponent("cases.json"))
        let examples = try JSONDecoder().decode([Example].self, from: data)
        let first = try XCTUnwrap(examples.first, "The synthetic corpus must not be empty")
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.wiltodelta.translatelikeme.dev/Dictation")
        let engine = DictationEngine(directory: cache)
        var stages = ["before_prepare_bytes": footprint()]
        let preparing = ContinuousClock.now
        try await engine.prepare { _ in }
        stages["prepare"] = String(describing: preparing.duration(to: .now))
        try await verifySpeechDetection(examples, engine: engine, cache: cache)
        stages["prepared_bytes"] = footprint()
        var report: [[String: String]] = []
        for example in examples {
            for repetition in 1...3 {
                let start = ContinuousClock.now
                let text = try await engine.transcribe(URL(fileURLWithPath: example.file))
                if example.expected.isEmpty { XCTAssertTrue(text.isEmpty, "Non-speech produced: \(text)") }
                for term in example.terms {
                    let expected = example.expected.lowercased().components(separatedBy: term.lowercased()).count - 1
                    let actual = text.lowercased().components(separatedBy: term.lowercased()).count - 1
                    XCTAssertGreaterThanOrEqual(actual, max(1, expected), "Expected \(term); got \(text)")
                }
                report.append(["expected": example.expected, "actual": text,
                               "repetition": String(repetition),
                               "latency": String(describing: start.duration(to: .now))])
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("results.json"))
        stages["after_recognition_bytes"] = footprint()
        let unloading = ContinuousClock.now
        await engine.unload()
        stages["unload"] = String(describing: unloading.duration(to: .now))
        stages["unloaded_bytes"] = footprint()
        let reloading = ContinuousClock.now
        // Disallow downloading for the reload, as in ordinary use after idle.
        try await engine.prepare(download: false) { _ in }
        stages["offline_reload"] = String(describing: reloading.duration(to: .now))
        let reloaded = try await engine.transcribe(URL(fileURLWithPath: first.file))
        XCTAssertFalse(reloaded.isEmpty)
        await engine.unload()
        try JSONSerialization.data(withJSONObject: stages, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("stages.json"))
    }

    private func verifySpeechDetection(_ examples: [Example], engine: DictationEngine, cache: URL) async throws {
        let root = try await engine.prepareSpeechDetector(in: cache, download: false) { _ in }
        let detector = try DictationSpeechDetector(
            directory: root.appendingPathComponent(DictationEngine.detectorModel))
        for example in examples {
            let samples = try DictationAudioLoader.load(URL(fileURLWithPath: example.file))
            XCTAssertEqual(try detector.containsSpeech(samples), !example.expected.isEmpty,
                           "Speech detection mismatch for synthetic case \(example.file)")
        }
    }

    private func footprint() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? String(info.phys_footprint) : "unavailable (kernel status \(status))"
    }

}

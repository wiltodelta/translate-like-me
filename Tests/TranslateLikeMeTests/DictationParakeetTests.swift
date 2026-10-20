import FluidAudio
import Foundation
@preconcurrency import WhisperKit
import XCTest
@testable import TranslateLikeMe

final class DictationParakeetTests: XCTestCase {
    func testRootModelPreparationValidatesVocabularyAndEveryCoreMLComponentOffline() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tlm-parakeet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = DictationEngine.parakeetSource
        let root = ModelDownloader(config: source).localRepoLocation(downloadBase: base)
        let fixture = SnapshotFixture(root: root, revision: source.revision, variant: "")
        for component in ModelNames.ASR.requiredModelsV3() {
            for part in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
                try fixture.write(component + "/" + part, bytes: Data("valid".utf8))
            }
        }
        let vocabulary = ModelNames.ASR.vocabularyFile
        try fixture.write(vocabulary, bytes: Data("vocabulary".utf8))
        let engine = DictationEngine(directory: base)
        let prepared = try await engine.prepareModels(model: .parakeetUltra, in: base, download: false) { _ in }
        XCTAssertEqual(prepared, root)
        try Data("corruption".utf8).write(to: fixture.file(vocabulary))
        XCTAssertEqual(try Data(contentsOf: fixture.file(vocabulary)), Data("corruption".utf8))
        do {
            _ = try await engine.prepareModels(model: .parakeetUltra, in: base, download: false) { _ in }
            XCTFail("A complete root must still validate the vocabulary hash")
        } catch DictationError.notReady {} catch { XCTFail("Unexpected error: \(error)") }
        try fixture.write(vocabulary, bytes: Data("vocabulary".utf8))
        let missing = fixture.file(ModelNames.ASR.jointV3File + "/weights/weight.bin")
        try FileManager.default.removeItem(at: missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        do {
            _ = try await engine.prepareModels(model: .parakeetUltra, in: base, download: false) { _ in }
            XCTFail("A missing joint weight must block offline preparation")
        } catch DictationError.notReady {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private struct Example: Decodable {
        let id: String
        let file: String
        let terms: [String]
        let expected: String
    }

    // Explicit opt-in, synthetic speech only. This prepares the actual pinned
    // download, then checks offline reloads and cross-runtime switching.
    func testParakeetDownloadsRecognizesAndSwitchesBackToWhisper() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TLM_PARAKEET_CHECK"] else {
            throw XCTSkip("Set TLM_PARAKEET_CHECK to a synthetic cases.json directory")
        }
        let root = URL(fileURLWithPath: directory)
        let examples = try JSONDecoder().decode([Example].self,
            from: Data(contentsOf: root.appendingPathComponent("cases.json")))
        let speech = try XCTUnwrap(examples.first { !$0.expected.isEmpty })
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.wiltodelta.translatelikeme.dev/Dictation")
        let engine = DictationEngine(directory: cache)
        var report: [[String: Any]] = []
        for (preparation, model) in [DictationModel.parakeetUltra, .turbo, .parakeetUltra].enumerated() {
            try await engine.prepare(model: model, download: report.isEmpty) { _ in }
            let loaded = await engine.loadedModel
            XCTAssertEqual(loaded, model)
            for example in examples {
                for repetition in 1...3 {
                    let text = try await engine.transcribe(URL(fileURLWithPath: example.file))
                    let normalized = text.lowercased().replacingOccurrences(of: "ё", with: "е")
                    let matches = example.terms.filter {
                        normalized.contains($0.lowercased().replacingOccurrences(of: "ё", with: "е"))
                    }.count
                    XCTAssertEqual(matches, example.terms.count, "Missing synthetic terms in \(example.id)")
                    XCTAssertEqual(text.isEmpty, example.expected.isEmpty)
                    report.append(["preparation": preparation, "model": model.rawValue, "id": example.id,
                                   "repetition": repetition, "matchedTerms": matches,
                                   "requiredTerms": example.terms.count,
                                   "empty": text.isEmpty])
                }
            }
        }
        await engine.unload()
        let unloaded = await engine.loadedModel
        XCTAssertNil(unloaded)
        try await engine.prepare(model: .parakeetUltra, download: false) { _ in }
        let offlineModel = await engine.loadedModel
        XCTAssertEqual(offlineModel, .parakeetUltra)
        let reloaded = try await engine.transcribe(URL(fileURLWithPath: speech.file))
        XCTAssertFalse(reloaded.isEmpty)
        await engine.unload()
        let cancelledPreparation = await verifyCancelledPreparation(engine)
        try JSONSerialization.data(withJSONObject: ["rows": report, "offlineReload": true,
            "unloaded": unloaded == nil, "cancelledPreparation": cancelledPreparation],
            options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("parakeet-check.json"))
    }
    private func verifyCancelledPreparation(_ engine: DictationEngine) async -> Bool {
        let cancelled = Task { @Sendable in
            withUnsafeCurrentTask { $0?.cancel() }
            try await engine.prepare(model: .parakeetUltra, download: false) { _ in }
        }
        do {
            try await cancelled.value
            XCTFail("Cancelled preparation must not report a ready runtime")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let afterCancellation = await engine.loadedModel
        XCTAssertNil(afterCancellation)
        return afterCancellation == nil
    }

}

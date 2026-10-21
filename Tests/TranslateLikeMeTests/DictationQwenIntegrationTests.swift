import Foundation
@preconcurrency import MLX
import XCTest
@testable import TranslateLikeMe

final class DictationQwenIntegrationTests: XCTestCase {
    private struct Example: Decodable {
        let id: String
        let file: String
        let expected: String
        let terms: [String]
    }

    // Explicit opt-in, synthetic speech only. This prepares the actual pinned
    // download, then checks offline reloads and cross-runtime switching.
    func testQwenDownloadsRecognizesAndSwitchesBackToWhisper() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TLM_QWEN_CHECK"] else {
            throw XCTSkip("Set TLM_QWEN_CHECK to a synthetic cases.json directory")
        }
        try DictationQwenTestSupport.configure()
        let root = URL(fileURLWithPath: directory)
        let examples = try JSONDecoder().decode([Example].self,
            from: Data(contentsOf: root.appendingPathComponent("cases.json")))
        let speech = try XCTUnwrap(examples.first { !$0.expected.isEmpty })
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.wiltodelta.translatelikeme.dev/Dictation")
        let engine = DictationEngine(directory: cache)
        var report: [[String: Any]] = []
        for (preparation, model) in [DictationModel.qwen3ASR, .turbo, .qwen3ASR].enumerated() {
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
        try await engine.prepare(model: .qwen3ASR, download: false) { _ in }
        let offlineModel = await engine.loadedModel
        XCTAssertEqual(offlineModel, .qwen3ASR)
        let reloaded = try await engine.transcribe(URL(fileURLWithPath: speech.file))
        XCTAssertFalse(reloaded.isEmpty)
        await engine.unload()
        let cancelledPreparation = await verifyCancelledPreparation(engine)
        try JSONSerialization.data(withJSONObject: ["rows": report, "offlineReload": true,
            "unloaded": unloaded == nil, "cancelledPreparation": cancelledPreparation],
            options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("qwen-check.json"))
    }
    func testOfflineReloadWithoutNetwork() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TLM_QWEN_CHECK"] else {
            throw XCTSkip("Run scripts/check-qwen.py for the offline check")
        }
        let endpoint = try XCTUnwrap(ProcessInfo.processInfo.environment["TLM_QWEN_OFFLINE_ENDPOINT"])
        let network = try await ProcessRunner.run(binary: "/usr/bin/curl",
            arguments: ["--noproxy", "*", "--max-time", "2", endpoint],
            environment: Translator.toolEnvironment(), deadline: ProcessRunner.deadline(after: 5))
        XCTAssertNotEqual(network.status, 0, "The reachable parent canary must be blocked by the sandbox")
        try DictationQwenTestSupport.configure()
        let root = URL(fileURLWithPath: directory)
        let examples = try JSONDecoder().decode([Example].self,
            from: Data(contentsOf: root.appendingPathComponent("cases.json")))
        let speech = try XCTUnwrap(examples.first { !$0.expected.isEmpty })
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.wiltodelta.translatelikeme.dev/Dictation")
        let engine = DictationEngine(directory: cache)
        try await engine.prepare(model: .qwen3ASR, download: false) { _ in }
        let loaded = await engine.loadedModel
        XCTAssertEqual(loaded, .qwen3ASR)
        let text = try await engine.transcribe(URL(fileURLWithPath: speech.file))
        let normalized = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        let matches = speech.terms.allSatisfy {
            normalized.contains($0.lowercased().replacingOccurrences(of: "ё", with: "е"))
        }
        XCTAssertTrue(matches)
        await engine.unload()
        try Data("verified".utf8).write(to: root.appendingPathComponent("offline-verified.txt"))
    }

    private func verifyCancelledPreparation(_ engine: DictationEngine) async -> Bool {
        let cancelled = Task { @Sendable in
            withUnsafeCurrentTask { $0?.cancel() }
            try await engine.prepare(model: .qwen3ASR, download: false) { _ in }
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

// Reuse the packaged kernels in CLI test hosts, which have no app Resources folder.
enum DictationQwenTestSupport {
    static func configure() throws {
        let path = ProcessInfo.processInfo.environment["TLM_QWEN_METALLIB"] ??
            FileManager.default.currentDirectoryPath + "/Translate Like Me.app/Contents/Resources/mlx.metallib"
        guard FileManager.default.fileExists(atPath: path) else { throw CocoaError(.fileNoSuchFile) }
        GPU.metallib = URL(fileURLWithPath: path)
    }
}

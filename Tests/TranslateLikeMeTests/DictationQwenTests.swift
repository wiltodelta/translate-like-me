import CryptoKit
import Foundation
@preconcurrency import WhisperKit
import XCTest
@testable import TranslateLikeMe

final class DictationQwenTests: XCTestCase {
    func testGreedyDecoderStopsAtAnEndTokenWithoutConsumingMoreSteps() throws {
        var calls = 0
        let tokens = try DictationQwenDecoding.decode(endTokens: [9], maximumTokens: 4) { previous in
            calls += 1
            XCTAssertEqual(previous, calls == 1 ? nil : calls - 1)
            return calls == 3 ? 9 : calls
        }
        XCTAssertEqual(tokens, [1, 2])
        XCTAssertEqual(calls, 3)
    }

    func testDecoderLimitRejectsPartialText() {
        var calls = 0
        XCTAssertThrowsError(try DictationQwenDecoding.decode(endTokens: [9], maximumTokens: 2) { _ in
            calls += 1
            return calls
        }) { XCTAssertTrue($0 is DictationQwenDecoding.Failure) }
        XCTAssertEqual(calls, 2)
    }

    func testRepetitionBackstopRejectsPartialText() {
        var calls = 0
        XCTAssertThrowsError(try DictationQwenDecoding.decode(endTokens: [9]) { _ in
            calls += 1
            return 1
        }) { XCTAssertTrue($0 is DictationQwenDecoding.Failure) }
        XCTAssertEqual(calls, 24)
    }

    func testCancellationStopsBeforeTheNextPrediction() async throws {
        let task = Task { @Sendable in
            var calls = 0
            do {
                _ = try DictationQwenDecoding.decode(endTokens: [9]) { _ in
                    calls += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                    return 1
                }
            } catch is CancellationError { return calls }
            return -1
        }
        let calls = try await task.value
        XCTAssertEqual(calls, 1)
    }

    func testLanguagePrefixRemovalPreservesRussianAndLiteralMarkersInSpeech() {
        XCTAssertEqual(DictationQwenDecoding.transcript(" language Russian<asr_text>Привет, MLX. "), "Привет, MLX.")
        XCTAssertEqual(DictationQwenDecoding.transcript("language English<asr_text>Say <asr_text> literally."),
                       "Say <asr_text> literally.")
        XCTAssertEqual(DictationQwenDecoding.transcript("  Привет, мир.  "), "Привет, мир.")
    }

    func testVerifiedQwenSnapshotRejectsCorruptionAndMissingWeightsOffline() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tlm-qwen-assets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = DictationQwen.source
        let root = ModelDownloader(config: source).localRepoLocation(downloadBase: base)
        let bytes = Data("fixture".utf8)
        let hash = Insecure.SHA1.hash(data: Data("blob \(bytes.count)\0".utf8) + bytes)
            .map { String(format: "%02x", $0) }.joined()
        for name in DictationQwen.files {
            let file = root.appendingPathComponent(name)
            let metadata = root.appendingPathComponent(".cache/huggingface/download/\(name).metadata")
            try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try bytes.write(to: file)
            try "\(source.revision)\n\(hash)\n1\n".write(to: metadata, atomically: true, encoding: .utf8)
        }
        let engine = DictationEngine(directory: base)
        let verified = try await engine.prepareModels(model: .qwen3ASR, in: base, download: false) { _ in }
        XCTAssertEqual(verified, root)
        let weights = root.appendingPathComponent("model.safetensors")
        try Data("corrupt".utf8).write(to: weights)
        XCTAssertEqual(try Data(contentsOf: weights), Data("corrupt".utf8))
        do {
            _ = try await engine.prepareModels(model: .qwen3ASR, in: base, download: false) { _ in }
            XCTFail("Same-size corruption must fail even with matching Hub metadata")
        } catch DictationError.notReady {}
        try FileManager.default.removeItem(at: weights)
        do {
            _ = try await engine.prepareModels(model: .qwen3ASR, in: base, download: false) { _ in }
            XCTFail("A partial snapshot must fail offline")
        } catch DictationError.notReady {}
    }
}

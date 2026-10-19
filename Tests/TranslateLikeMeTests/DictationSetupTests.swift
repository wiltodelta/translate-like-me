import CryptoKit
import Foundation
@preconcurrency import WhisperKit
import XCTest
@testable import TranslateLikeMe

final class DictationSetupTests: XCTestCase {
    func testCompleteSnapshotRejectsCorruptGitBlobEvenWhenSDKAcceptsIt() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tlm-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = DictationEngine.detectorSource
        let model = DictationEngine.detectorModel
        for file in ["coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin"] {
            try await partialSnapshot(source: source, model: model, file: file, bytes: Data("valid".utf8), in: base)
        }
        let root = ModelDownloader(config: source).localRepoLocation(downloadBase: base)
        let damaged = root.appendingPathComponent(model + "/model.mil")
        try Data("wrong".utf8).write(to: damaged)
        XCTAssertEqual(try Data(contentsOf: damaged), Data("wrong".utf8))
        // The SDK accepts this complete snapshot despite a stale Git blob hash.
        _ = try await ModelDownloader(config: source).resolveRepo(patterns: [model + "/*"],
                                                                 downloadBase: base, download: false)
        do {
            _ = try await DictationEngine(directory: base).prepareSpeechDetector(in: base, download: false) { _ in }
            XCTFail("Corrupt non-LFS files must never count as an installed model")
        } catch DictationError.notReady {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testPartialSpeechDetectorIsNotAnInstalledModel() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tlm-vad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try await partialSnapshot(source: DictationEngine.detectorSource,
                                      model: DictationEngine.detectorModel, file: "metadata.json",
                                      bytes: Data("[]\n".utf8), in: base)
        let engine = DictationEngine(directory: base)
        do {
            _ = try await engine.prepareSpeechDetector(in: base, download: false) { _ in }
            XCTFail("A partial speech detector must never be reported ready")
        } catch DictationError.notReady {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testLowStorageStopsPreparationBeforeModelAccess() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tlm-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        for gigabytes in [0, 1, 3, 7] {
            let engine = DictationEngine(directory: base, availableStorage: { _ in Int64(gigabytes) * 1_000_000_000 })
            do {
                try await engine.prepare(download: false) { _ in }
                XCTFail("Low storage must stop before accessing models")
            } catch DictationError.insufficientStorage {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
        }
        let engine = DictationEngine(directory: base, availableStorage: { _ in 8_000_000_000 })
        do {
            try await engine.prepare(download: false) { _ in }
            XCTFail("No model is installed")
        } catch DictationError.notReady {} catch { XCTFail("Unexpected error at the storage boundary: \(error)") }
    }

    func testPartialSnapshotIsNotAnInstalledModelEvenWhenSDKAcceptsIt() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tlm-setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try await partialSnapshot(source: DictationEngine.modelSource,
                                      model: DictationModel.turbo.variant, file: "config.json",
                                      bytes: Data("{}\n".utf8), in: base)
        let engine = DictationEngine(directory: base)
        do {
            _ = try await engine.prepareModels(in: base, download: false) { _ in }
            XCTFail("A partial snapshot must never be reported ready")
        } catch DictationError.notReady {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private func partialSnapshot(source: ModelDownloadConfig, model: String, file: String,
                                 bytes: Data, in base: URL) async throws {
        let downloader = ModelDownloader(config: source)
        let root = downloader.localRepoLocation(downloadBase: base)
        let relative = model + "/" + file
        let destination = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: destination)
        let blob = Data("blob \(bytes.count)\0".utf8) + bytes
        let hash = Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        let metadata = root.appendingPathComponent(".cache/huggingface/download/" + relative + ".metadata")
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "\(source.revision)\n\(hash)\n1\n".write(to: metadata, atomically: true, encoding: .utf8)
        // Prove that the fixture reaches the real SDK's partial cache-hit path.
        let accepted = try await downloader.resolveRepo(patterns: [model + "/*"],
                                                        downloadBase: base, download: false)
        XCTAssertEqual(accepted.resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
    }

}

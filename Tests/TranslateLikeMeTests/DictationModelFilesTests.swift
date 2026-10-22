import Foundation
import XCTest
@preconcurrency import WhisperKit
@testable import TranslateLikeMe

final class DictationModelFilesTests: XCTestCase {
    func testRemovalPreservesEveryNeighborAndSharedAssets() throws {
        for removed in DictationModel.allCases {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: base) }
            let files = DictationModelFiles(base: base)
            for model in DictationModel.allCases {
                try seed(files.folder(for: model).appendingPathComponent("sentinel"))
                if let tokenizer = model.tokenizer {
                    let root = ModelDownloader(config: ModelDownloadConfig(modelRepo: tokenizer.repository,
                        revision: tokenizer.revision)).localRepoLocation(downloadBase: base)
                    try seed(root.appendingPathComponent("tokenizer.json"))
                }
            }
            let shared = ModelDownloader(config: DictationEngine.detectorSource)
                .localRepoLocation(downloadBase: base).appendingPathComponent("sentinel")
            try seed(shared)
            let cachedVariant = files.root(for: .turbo).appendingPathComponent("other-variant/sentinel")
            try seed(cachedVariant)
            XCTAssertTrue(FileManager.default.fileExists(atPath: cachedVariant.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: files.folder(for: removed).path))
            try files.remove(removed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: files.folder(for: removed).path))
            for neighbor in DictationModel.allCases where neighbor != removed {
                XCTAssertTrue(FileManager.default.fileExists(
                    atPath: files.folder(for: neighbor).appendingPathComponent("sentinel").path),
                    "Removing \(removed) deleted \(neighbor)")
                if let tokenizer = neighbor.tokenizer {
                    let root = ModelDownloader(config: ModelDownloadConfig(modelRepo: tokenizer.repository,
                        revision: tokenizer.revision)).localRepoLocation(downloadBase: base)
                    XCTAssertTrue(FileManager.default.fileExists(
                        atPath: root.appendingPathComponent("tokenizer.json").path))
                }
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: cachedVariant.path))
            try files.remove(removed) // Idempotent when files are already absent.
        }
    }

    func testPresenceRequiresEveryNonemptyComponentForEveryModel() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let files = DictationModelFiles(base: base)
        for model in DictationModel.allCases {
            XCTAssertFalse(files.isDownloaded(model))
            let required = DictationEngine.requiredFiles(for: model)
            for part in required { try seed(files.folder(for: model).appendingPathComponent(part)) }
            XCTAssertTrue(files.isDownloaded(model))
            let damaged = files.folder(for: model).appendingPathComponent(required[0])
            try Data().write(to: damaged)
            XCTAssertFalse(files.isDownloaded(model))
        }
    }

    private func seed(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
    }
}

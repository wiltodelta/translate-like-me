import CryptoKit
import Foundation
import os
import XCTest
@testable import TranslateLikeMe

final class ModelSnapshotTests: XCTestCase {
    func testCompleteSnapshotValidatesGitAndLFSFilesWithoutFetching() async throws {
        let fixture = SnapshotFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.write("model.mil", bytes: Data("program".utf8))
        // Cross the streaming hash's chunk boundary.
        try fixture.write("weights/weight.bin", bytes: Data(repeating: 42, count: 1_100_000), lfs: true)
        let root = try await fixture.snapshot.prepare(download: false) { XCTFail("Offline reload must not fetch") }
        XCTAssertEqual(root, fixture.root)
    }

    func testPartialSnapshotRemovesCorruptFilesBeforeResumingAndKeepsGoodFiles() async throws {
        let fixture = SnapshotFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.write("config.json", bytes: Data("{}".utf8))
        try fixture.write("weights/weight.bin", bytes: Data("weights".utf8), lfs: true)
        let damaged = fixture.file("weights/weight.bin")
        try Data("changed".utf8).write(to: damaged)
        XCTAssertEqual(try Data(contentsOf: damaged), Data("changed".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file("model.mil").path))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        _ = try await fixture.snapshot.prepare(download: true) {
            calls.withLock { $0 += 1 }
            XCTAssertFalse(FileManager.default.fileExists(atPath: damaged.path),
                           "Remove the corrupt cached weight before the SDK's metadata fast path")
            XCTAssertEqual(try Data(contentsOf: fixture.file("config.json")), Data("{}".utf8))
            try fixture.write("weights/weight.bin", bytes: Data("weights".utf8), lfs: true)
            try fixture.write("model.mil", bytes: Data("program".utf8))
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        _ = try await fixture.snapshot.prepare(download: false) { XCTFail("Repaired snapshot must be offline") }
    }

    func testDownloadedSnapshotMustBeCompleteAndPassHashes() async throws {
        for corrupt in [false, true] {
            let fixture = SnapshotFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let calls = OSAllocatedUnfairLock(initialState: 0)
            do {
                _ = try await fixture.snapshot.prepare(download: true) {
                    calls.withLock { $0 += 1 }
                    try fixture.write("model.mil", bytes: Data("program".utf8))
                    if corrupt {
                        try fixture.write("weights/weight.bin", bytes: Data("weights".utf8), lfs: true)
                        try Data("changed".utf8).write(to: fixture.file("model.mil"))
                        XCTAssertEqual(try Data(contentsOf: fixture.file("model.mil")), Data("changed".utf8))
                    } else {
                        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file("weights/weight.bin").path))
                    }
                }
                XCTFail("A completed transport is not proof of a valid snapshot")
            } catch is ModelSnapshot.Incomplete {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(calls.withLock { $0 }, 1)
        }
    }

    func testVariantStillRejectsUnverifiedAssetsInsideACacheNamedDirectory() async throws {
        let fixture = SnapshotFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.write("model.mil", bytes: Data("program".utf8))
        try fixture.write("weights/weight.bin", bytes: Data("weights".utf8), lfs: true)
        let unverified = fixture.file(".cache/unverified.bin")
        try FileManager.default.createDirectory(at: unverified.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try Data("unverified".utf8).write(to: unverified)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unverified.path))
        do {
            _ = try await fixture.snapshot.prepare(download: false) { XCTFail("Offline reload must not fetch") }
            XCTFail("Only repository-root Hub metadata may be excluded from validation")
        } catch is ModelSnapshot.Incomplete {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRootSnapshotValidatesAssetsWithoutTreatingHubMetadataAsModelFiles() async throws {
        let fixture = SnapshotFixture(variant: "")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.write("model.mil", bytes: Data("program".utf8))
        try fixture.write("weights/weight.bin", bytes: Data("weights".utf8), lfs: true)
        let metadata = fixture.root.appendingPathComponent(".cache/huggingface/download/model.mil.metadata")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
        let root = try await fixture.snapshot.prepare(download: false) { XCTFail("A complete root is offline") }
        XCTAssertEqual(root, fixture.root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
    }

    func testSnapshotRejectsMetadataFromAnotherRevision() async throws {
        let fixture = SnapshotFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.write("model.mil", bytes: Data("program".utf8), revision: String(repeating: "b", count: 40))
        try fixture.write("weights/weight.bin", bytes: Data("weights".utf8), lfs: true)
        do {
            _ = try await fixture.snapshot.prepare(download: false) { XCTFail("Offline reload must not fetch") }
            XCTFail("A cache hit must belong to the pinned revision")
        } catch is ModelSnapshot.Incomplete {} catch { XCTFail("Unexpected error: \(error)") }
    }
}

struct SnapshotFixture: Sendable {
    let root: URL
    let revision: String
    let variant: String

    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("tlm-snapshot-\(UUID().uuidString)"),
         revision: String = String(repeating: "a", count: 40), variant: String = "speech.mlmodelc") {
        self.root = root
        self.revision = revision
        self.variant = variant
    }

    var snapshot: ModelSnapshot {
        ModelSnapshot(root: root, revision: revision, variant: variant,
                      required: ["model.mil", "weights/weight.bin"])
    }

    func file(_ name: String) -> URL { root.appendingPathComponent(variant + "/" + name) }

    func write(_ name: String, bytes: Data, lfs: Bool = false, revision: String? = nil) throws {
        let destination = file(name)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: destination)
        let hash: String
        if lfs {
            hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        } else {
            let blob = Data("blob \(bytes.count)\0".utf8) + bytes
            hash = Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        }
        let relative = variant.isEmpty ? name : variant + "/" + name
        let metadata = root.appendingPathComponent(".cache/huggingface/download/" + relative + ".metadata")
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "\(revision ?? self.revision)\n\(hash)\n1\n".write(to: metadata, atomically: true, encoding: .utf8)
    }
}

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

    func testDroppedConnectionResumesWhileEachAttemptAddsBytes() async throws {
        let failures = ModelSnapshot.attemptsWithoutProgress + 1
        let run = try await retrying { fixture, call in
            if call <= failures {
                // Each attempt appends to the Hub's partial file, as a Range request would.
                let partial = fixture.root.appendingPathComponent(".cache/huggingface/download/weight.incomplete")
                try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data(repeating: 1, count: call * 10).write(to: partial)
                throw URLError(.networkConnectionLost)
            }
            try fixture.write("model.mil", bytes: Data("program".utf8))
            try fixture.write("weights/weight.bin", bytes: Data("weights".utf8), lfs: true)
        }
        XCTAssertNil(run.error)
        XCTAssertEqual(run.calls, failures + 1)
        XCTAssertEqual(run.pauses, Array(repeating: 0, count: failures),
                       "Attempts that add bytes never count toward giving up")
    }

    func testDroppedConnectionGivesUpAfterAttemptsWithoutProgress() async throws {
        let run = try await retrying { _, _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual((run.error as? URLError)?.code, .notConnectedToInternet)
        XCTAssertEqual(run.calls, ModelSnapshot.attemptsWithoutProgress)
        XCTAssertEqual(run.pauses, Array(1..<ModelSnapshot.attemptsWithoutProgress))
    }

    func testStallAfterEarlierProgressStillGivesUp() async throws {
        let limit = ModelSnapshot.attemptsWithoutProgress
        let run = try await retrying { fixture, call in
            // A runaway retry loop stops here instead of hanging the suite.
            if call > limit * 4 { throw CocoaError(.fileReadUnknown) }
            if call == 1 { try fixture.write("model.mil", bytes: Data("program".utf8)) }
            throw URLError(.networkConnectionLost)
        }
        XCTAssertEqual((run.error as? URLError)?.code, .networkConnectionLost)
        XCTAssertEqual(run.calls, 1 + limit, "Progress is measured against the previous attempt, not the start")
        XCTAssertEqual(run.pauses, Array(0..<limit))
    }

    func testCancellationAndOtherFailuresAreNotRetried() async throws {
        for failure in [URLError(.cancelled), CocoaError(.fileWriteOutOfSpace)] as [Error] {
            let run = try await retrying { _, _ in throw failure }
            XCTAssertNotNil(run.error, "\(failure) must reach the caller")
            XCTAssertEqual(run.calls, 1)
            XCTAssertEqual(run.pauses, [], "\(failure) must not be retried")
        }
    }

    private struct RetryRun {
        let calls: Int
        let pauses: [Int]
        let error: Error?
    }

    private func retrying(_ fetch: @escaping @Sendable (SnapshotFixture, Int) throws -> Void) async throws -> RetryRun {
        let fixture = SnapshotFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let pauses = OSAllocatedUnfairLock(initialState: [Int]())
        var snapshot = fixture.snapshot
        snapshot.pause = { stalled in pauses.withLock { $0.append(stalled) } }
        var failure: Error?
        do {
            _ = try await snapshot.prepare(download: true) {
                try fetch(fixture, calls.withLock { $0 += 1; return $0 })
            }
        } catch {
            failure = error
        }
        return RetryRun(calls: calls.withLock { $0 }, pauses: pauses.withLock { $0 }, error: failure)
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

import Foundation
import os
import XCTest
@testable import TranslateLikeMe

final class ProcessRunnerTests: XCTestCase {
    private static func run(_ script: String, input: String? = nil,
                            deadline: @escaping ProcessRunner.Deadline = ProcessRunner.deadline(after: 10),
                            limit: Int = 8 * 1024 * 1024) async throws -> ProcessRunner.Output {
        try await ProcessRunner.run(binary: "/bin/sh", arguments: ["-c", script], input: input,
                                    environment: ["PATH": "/usr/bin:/bin"], deadline: deadline, outputLimit: limit)
    }

    func testDrainsBothFullPipesBeforeChildExitAndWhileWritingLargeInput() async throws {
        let input = String(repeating: "input", count: 250_000)
        let result = try await Self.run("""
            head -c 1048576 /dev/zero
            head -c 1048576 /dev/zero >&2
            cat
            """, input: input)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stderr.utf8.count, 1_048_576)
        XCTAssertEqual(result.stdout, String(repeating: "\0", count: 1_048_576) + input)
    }

    func testPreservesFailureStatusAndBothStreams() async throws {
        let result = try await Self.run("printf out; printf err >&2; exit 7")
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.stdout, "out")
        XCTAssertEqual(result.stderr, "err")
    }

    func testAbsentInputDeliversEOF() async throws {
        let result = try await Self.run("exec cat")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
    }

    func testEarlyExitWhileWritingLargeInputDoesNotSignalTheParent() async throws {
        let result = try await Self.run("printf done", input: String(repeating: "x", count: 1_000_000))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "done")
    }

    func testMissingExecutableThrowsWithoutWaitingForDeadline() async {
        do {
            _ = try await ProcessRunner.run(binary: "/nonexistent/tlm-test", arguments: [], environment: [:])
            XCTFail("Missing executable must fail")
        } catch { XCTAssertFalse(error is CancellationError) }
    }

    func testDeadlineTerminatesAnUnresponsiveChild() async {
        let clock = ManualDeadline()
        let installed = expectation(description: "Child launched and deadline installed")
        let task = Task { try await Self.run("exec sleep 600", deadline: clock.schedule(installed)) }
        await fulfillment(of: [installed], timeout: 5)
        clock.expire()
        do {
            _ = try await task.value
            XCTFail("Deadline must stop the child")
        } catch ProcessRunner.Failure.timedOut { } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCancellationTerminatesAChildThatDoesNotReadStdin() async {
        let installed = expectation(description: "Child launched")
        let clock = ManualDeadline()
        let task = Task {
            try await Self.run("exec sleep 600", input: String(repeating: "x", count: 1_000_000),
                                 deadline: clock.schedule(installed))
        }
        await fulfillment(of: [installed], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled task must stop the child")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testOutputLimitStopsAnUnboundedProducer() async {
        do {
            _ = try await Self.run("exec yes", limit: 4096)
            XCTFail("Unbounded output must fail")
        } catch ProcessRunner.Failure.outputTooLarge { } catch { XCTFail("Unexpected error: \(error)") }
    }
}

private final class ManualDeadline: Sendable {
    private let callback = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    func schedule(_ installed: XCTestExpectation) -> ProcessRunner.Deadline {
        { [self] expire in
            callback.withLock { $0 = expire }
            installed.fulfill()
            return { [self] in callback.withLock { $0 = nil } }
        }
    }

    func expire() {
        let action = callback.withLock { $0 }
        action?()
    }
}

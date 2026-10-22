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

    // agy finds the app's agent in its working directory (Antigravity.workspace).
    func testRunsInTheGivenDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await ProcessRunner.run(binary: "/bin/pwd", arguments: ["-P"], environment: [:],
                                                 directory: directory)
        // pwd -P prints /private/var where the URL says /var.
        let physical = try XCTUnwrap(realpath(directory.path, nil))
        defer { free(physical) }
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .newlines), String(cString: physical))
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
        let deadline = clock.schedule(installed)
        let task = Task { @Sendable in
            try await ProcessRunnerTests.run("exec sleep 600", deadline: deadline)
        }
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
        let deadline = clock.schedule(installed)
        let task = Task { @Sendable in
            try await ProcessRunnerTests.run("exec sleep 600", input: String(repeating: "x", count: 1_000_000),
                                            deadline: deadline)
        }
        await fulfillment(of: [installed], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled task must stop the child")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testDeadlineTerminatesDescendantAfterItsParentExits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("process-tree-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ManualDeadline()
        let installed = expectation(description: "Parent launched")
        let deadline = clock.schedule(installed)
        let task = Task { @Sendable in
            try await ProcessRunner.run(binary: "/bin/sh", arguments: ["-c", """
                sleep 600 &
                printf '%s %s' "$$" "$!" > pids
                while [ ! -f release ]; do sleep 0.01; done
                exit 0
                """], environment: ["PATH": "/usr/bin:/bin"], directory: directory, deadline: deadline)
        }
        defer { task.cancel() }
        await fulfillment(of: [installed], timeout: 5)
        let pids = try await ProcessRunnerTests.fixturePIDs(in: directory)
        XCTAssertEqual(pids.count, 2)
        guard pids.count == 2 else { return }
        let parent = pids[0], child = pids[1]
        defer {
            if kill(parent, 0) == 0 { kill(parent, SIGKILL) }
            if kill(child, 0) == 0 { kill(child, SIGKILL) }
        }
        XCTAssertEqual(getpgid(parent), parent, "The fixture must own its process group")
        XCTAssertEqual(getpgid(child), parent)
        let childExited = expectation(description: "Descendant terminated by deadline")
        let exitMonitor = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global())
        exitMonitor.setEventHandler { childExited.fulfill() }
        exitMonitor.resume()
        defer { exitMonitor.cancel() }
        try Data().write(to: directory.appendingPathComponent("release"))
        let deadlineForExit = ContinuousClock.now.advanced(by: .seconds(5))
        while kill(parent, 0) == 0, ContinuousClock.now < deadlineForExit {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(kill(parent, 0), -1, "The parent must exit before the deadline fires")
        XCTAssertEqual(kill(child, 0), 0, "The descendant must still hold the output pipes")
        clock.expire()
        do {
            _ = try await task.value
            XCTFail("Deadline must stop the descendant holding the pipes")
        } catch ProcessRunner.Failure.timedOut { } catch { XCTFail("Unexpected error: \(error)") }
        await fulfillment(of: [childExited], timeout: 5)
    }

    private static func fixturePIDs(in directory: URL) async throws -> [pid_t] {
        let pidsFile = directory.appendingPathComponent("pids")
        let deadlineForReadiness = ContinuousClock.now.advanced(by: .seconds(5))
        var pids: [pid_t] = []
        while pids.count != 2, ContinuousClock.now < deadlineForReadiness {
            pids = ((try? String(contentsOf: pidsFile, encoding: .utf8)) ?? "")
                .split(separator: " ").compactMap { pid_t($0) }
            if pids.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        }
        return pids
    }

    // claude writes its answer about 0.6 s before it exits; the run returns at
    // the answer and the deadline still reaps a child that never exits.
    func testAnsweredRunReturnsBeforeExitAndTheDeadlineReapsTheChild() async throws {
        let clock = ManualDeadline()
        let installed = expectation(description: "Child launched and deadline installed")
        let result = try await ProcessRunner.run(binary: "/bin/sh", arguments: ["-c", "echo $$; exec sleep 600"],
            environment: ["PATH": "/usr/bin:/bin"], deadline: clock.schedule(installed),
            answered: { $0.last == UInt8(ascii: "\n") })
        await fulfillment(of: [installed], timeout: 5)
        XCTAssertEqual(result.status, 0)
        let pid = try XCTUnwrap(pid_t(result.stdout.trimmingCharacters(in: .newlines)))
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        XCTAssertEqual(kill(pid, 0), 0, "The answer must arrive while the child still runs")
        XCTAssertTrue(clock.isScheduled)
        let exited = expectation(description: "Child killed at the deadline")
        let monitor = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        monitor.setEventHandler { exited.fulfill() }
        monitor.resume()
        defer { monitor.cancel() }
        clock.expire()
        await fulfillment(of: [exited], timeout: 5)
    }

    func testAnsweredChildThatExitsCancelsTheDeadline() async throws {
        let clock = ManualDeadline()
        let installed = expectation(description: "Deadline installed")
        let result = try await ProcessRunner.run(binary: "/bin/sh", arguments: ["-c", "echo done; sleep 0.2"],
            environment: ["PATH": "/usr/bin:/bin"], deadline: clock.schedule(installed),
            answered: { $0.last == UInt8(ascii: "\n") })
        await fulfillment(of: [installed], timeout: 5)
        XCTAssertEqual(result.stdout, "done\n")
        let until = ContinuousClock.now.advanced(by: .seconds(5))
        while clock.isScheduled, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(clock.isScheduled, "An exit after the answer must drop the deadline")
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

    var isScheduled: Bool { callback.withLock { $0 != nil } }

    func expire() {
        let action = callback.withLock { $0 }
        action?()
    }
}

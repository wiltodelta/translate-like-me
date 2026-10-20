import Foundation
import Darwin

// One lifecycle for translations, sign-in probes and binary lookup. DispatchIO
// drains both pipes while the child runs, including while it consumes stdin.
enum ProcessRunner {
    struct Output: Sendable {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    enum Failure: LocalizedError {
        case timedOut
        case outputTooLarge
        case io(Int32)

        var errorDescription: String? {
            switch self {
            case .timedOut: String(localized: "The engine took too long to respond. Try again.")
            case .outputTooLarge: String(localized: "The engine returned too much output. Try a smaller selection.")
            case .io: String(localized: "Couldn't communicate with the engine. Try again.")
            }
        }
    }

    // The injectable deadline lets tests expire a running child without waiting
    // on the wall clock. The returned closure cancels the scheduled deadline.
    typealias Deadline = @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void)

    static func deadline(after seconds: Double) -> Deadline {
        { expire in
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + seconds)
            timer.setEventHandler(handler: expire)
            timer.resume()
            return { timer.cancel() }
        }
    }

    // `directory` is the child's working directory, the temporary directory by
    // default.
    static func run(binary: String, arguments: [String], input: String? = nil,
                    environment: [String: String], directory: URL? = nil,
                    deadline: @escaping Deadline = deadline(after: 120),
                    outputLimit: Int = 8 * 1024 * 1024) async throws -> Output {
        let session = Session(outputLimit: outputLimit, deadline: deadline, directory: directory)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.start(binary: binary, arguments: arguments, input: input,
                              environment: environment, continuation: continuation)
            }
        } onCancel: {
            session.cancel()
        }
    }
}

// All mutable state and DispatchIO callbacks belong to queue. Cancellation may
// arrive before start, after exit, or while stdin is still being written.
private final class Session: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.wiltodelta.translatelikeme.process")
    private let process = Process()
    private let outputLimit: Int
    private let scheduleDeadline: ProcessRunner.Deadline
    private var continuation: CheckedContinuation<ProcessRunner.Output, Error>?
    private var channels: [DispatchIO] = []
    private var stdout = Data()
    private var stderr = Data()
    private var endedStreams = 0
    private var exited = false
    private var cancelled = false
    private var stoppingError: Error?
    private var cancelDeadline: (@Sendable () -> Void)?

    init(outputLimit: Int, deadline: @escaping ProcessRunner.Deadline, directory: URL?) {
        self.outputLimit = outputLimit
        scheduleDeadline = deadline
        process.currentDirectoryURL = directory ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    func start(binary: String, arguments: [String], input: String?, environment: [String: String],
               continuation: CheckedContinuation<ProcessRunner.Output, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            guard !cancelled else { finish(.failure(CancellationError())); return }
            launch(binary: binary, arguments: arguments, input: input, environment: environment)
            guard self.continuation != nil else { return }
            cancelDeadline = scheduleDeadline { [self] in queue.async { self.stop(ProcessRunner.Failure.timedOut) } }
        }
    }

    func cancel() {
        queue.async { [self] in
            cancelled = true
            stop(CancellationError())
        }
    }

    private func launch(binary: String, arguments: [String], input: String?, environment: [String: String]) {
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin.fileHandleForReading
        process.terminationHandler = { [self] _ in
            queue.async { self.exited = true; self.completeIfReady() }
        }
        do {
            try process.run()
            read(out.fileHandleForReading, isError: false)
            read(err.fileHandleForReading, isError: true)
            if let input { write(Data(input.utf8), to: stdin.fileHandleForWriting) }
            // Passing a FileHandle for stdin leaves the parent's read end ours.
            try? stdin.fileHandleForReading.close()
        } catch {
            finish(.failure(error))
        }
    }

    private func channel(_ handle: FileHandle) -> DispatchIO {
        let descriptor = dup(handle.fileDescriptor)
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        let channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in
            Darwin.close(descriptor)
        }
        try? handle.close()
        channel.setLimit(lowWater: 1)
        channels.append(channel)
        return channel
    }

    private func read(_ handle: FileHandle, isError: Bool) {
        channel(handle).read(offset: 0, length: Int.max, queue: queue) { [self] done, data, error in
            guard continuation != nil else { return }
            if let data {
                if isError { stderr.append(contentsOf: data) } else { stdout.append(contentsOf: data) }
            }
            guard stdout.count + stderr.count <= outputLimit else {
                stop(ProcessRunner.Failure.outputTooLarge)
                return
            }
            guard error == 0 else { stop(ProcessRunner.Failure.io(error)); return }
            if done { endedStreams += 1; completeIfReady() }
        }
    }

    private func write(_ data: Data, to handle: FileHandle) {
        let writer = channel(handle)
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        writer.write(offset: 0, data: bytes, queue: queue) { done, _, _ in
            // A CLI may exit without consuming stdin; its exit status and output
            // decide the result. Closing on completion also delivers EOF.
            if done { writer.close() }
        }
    }

    private func completeIfReady() {
        if exited, let stoppingError { finish(.failure(stoppingError)); return }
        guard exited, endedStreams == 2 else { return }
        finish(.success(.init(stdout: String(data: stdout, encoding: .utf8) ?? "",
                              stderr: String(data: stderr, encoding: .utf8) ?? "", status: process.terminationStatus)))
    }

    private func stop(_ error: Error) {
        guard continuation != nil, stoppingError == nil else { return }
        stoppingError = error
        if process.isRunning {
            let pid = process.processIdentifier
            // NSTask normally creates its own process group. Never signal a
            // shared group (which could contain the app or its launcher).
            kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
        }
        channels.forEach { $0.close(flags: .stop) }
        if exited { finish(.failure(error)) }
    }

    private func finish(_ result: Result<ProcessRunner.Output, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        process.terminationHandler = nil
        cancelDeadline?()
        cancelDeadline = nil
        channels.forEach { $0.close(flags: .stop) }
        channels.removeAll()
        continuation.resume(with: result)
    }
}

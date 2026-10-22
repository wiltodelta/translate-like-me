import Foundation
import os

private let playbackLog = Logger.app("dictation")

// The capture queue owns the current hold. Media commands run independently,
// so querying a slow player never delays microphone startup or stopping.
final class DictationMediaPlayback {
    typealias Command = @Sendable (_ action: String, _ receipt: String?) async throws -> String
    private let command: Command
    private let pending = DispatchGroup()
    private var hold: DictationMediaHold?
    private var previous: Task<Void, Never>?

    init(command: @escaping Command = DictationMediaPlayback.run) { self.command = command }

    func begin() {
        guard hold == nil else { return }
        let hold = DictationMediaHold()
        self.hold = hold
        let command = command
        let pending = pending
        let previous = previous
        pending.enter()
        self.previous = Task {
            defer { pending.leave() }
            await previous?.value
            do {
                guard !hold.hasEnded else { return }
                let response = try await command("pause", nil)
                guard let receipt = Self.receipt(from: response) else {
                    if Self.status(from: response) != "ignored" {
                        playbackLog.notice("Dictation media pause not confirmed; output mute remains the fallback")
                    }
                    return
                }
                playbackLog.notice("Dictation paused system media")
                // Release during the command still restores its confirmed pause.
                await hold.waitForEnd()
                let restoration = try await command("resume", receipt)
                let restored = Self.status(from: restoration) == "resumed"
                playbackLog.notice("Dictation media resume confirmed: \(restored)")
            } catch {
                // An uncertain pause is never followed by an unconditional Play.
                playbackLog.notice("Dictation media control unavailable; output mute remains the fallback")
            }
        }
    }

    func end() {
        hold?.end()
        hold = nil
    }

    // Called only during termination, off the main actor. Each command has a
    // bounded deadline; allow both an in-flight pause and its restoration.
    func finishPending() { pending.wait() }

    private static func receipt(from response: String) -> String? {
        guard let data = response.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["status"] as? String == "paused", let receipt = result["receipt"] as? [String: Any],
              let encoded = try? JSONSerialization.data(withJSONObject: receipt),
              let text = String(data: encoded, encoding: .utf8) else { return nil }
        return text
    }

    private static func status(from response: String) -> String? {
        guard let data = response.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return result["status"] as? String
    }

    private static func run(_ action: String, _ receipt: String?) async throws -> String {
        var arguments = ["-l", "JavaScript", "-e", DictationMediaScript.source, "--", action]
        if let receipt { arguments.append(receipt) }
        let output = try await ProcessRunner.run(binary: "/usr/bin/osascript", arguments: arguments,
            environment: ProcessInfo.processInfo.environment, deadline: ProcessRunner.deadline(after: 2.5),
            outputLimit: 16 * 1024)
        return output.status == 0 ? output.stdout : ""
    }
}

// A release signal, not cancellation: cancellation could interrupt the very
// command that owns the pause and lose the receipt needed to restore it.
private final class DictationMediaHold: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    private var continuation: CheckedContinuation<Void, Never>?

    var hasEnded: Bool { lock.withLock { ended } }

    func waitForEnd() async {
        await withCheckedContinuation { continuation in
            let alreadyEnded = lock.withLock {
                if ended { return true }
                self.continuation = continuation
                return false
            }
            if alreadyEnded { continuation.resume() }
        }
    }

    func end() {
        let continuation = lock.withLock {
            ended = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

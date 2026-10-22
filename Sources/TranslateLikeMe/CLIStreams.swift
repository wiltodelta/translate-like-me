import Foundation

// Each CLI finishes its answer 0.5-1.1 s before it exits
// (docs/cli-translation-latency.md), so translations read their
// JSON event streams and end the run at the answer (`ProcessRunner.run(answered:)`).
// A failure waits for the exit status and is given back to `FailureDetail` in
// the shape the CLI's plain output had, for the sign-in and limit detectors.
protocol CLIAnswerStream {
    // The complete answer, nil until the stream reports it.
    static func answer(in stdout: String) -> String?
    static var isAnswered: @Sendable (Data) -> Bool { get }
    // A failed run as the CLI's plain output showed it.
    static func plain(_ output: ProcessRunner.Output) -> ProcessRunner.Output
}

enum CLIStream {
    // Complete lines only: the last one may still be growing.
    static func events(in stdout: String) -> [[String: Any]] {
        let end = stdout.hasSuffix("\n") ? stdout.endIndex : stdout.lastIndex(of: "\n") ?? stdout.startIndex
        let complete = stdout[..<end]
        return complete.split(whereSeparator: \.isNewline).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    // Reads only the last complete line until it is the stream's final event,
    // so a long stream is not parsed again for every chunk.
    static func answered(at final: String, _ answer: @escaping @Sendable (String) -> String?)
        -> @Sendable (Data) -> Bool {
        { data in
            guard data.last == UInt8(ascii: "\n") else { return false }
            let line = data.dropLast().split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).last
            guard let line, let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  event["type"] as? String == final else { return false }
            return String(data: data, encoding: .utf8).flatMap(answer) != nil
        }
    }
}

// `claude -p --output-format stream-json --verbose`: the result event holds the
// answer, or with `is_error` the message text mode prints.
enum ClaudeStream: CLIAnswerStream {
    struct Result: Equatable {
        let text: String
        let isError: Bool
    }

    static func result(in stdout: String) -> Result? {
        guard let event = CLIStream.events(in: stdout).last(where: { $0["type"] as? String == "result" }) else {
            return nil
        }
        return Result(text: event["result"] as? String ?? "", isError: event["is_error"] as? Bool ?? true)
    }

    static func answer(in stdout: String) -> String? {
        result(in: stdout).flatMap { $0.isError ? nil : $0.text }
    }

    static let isAnswered = CLIStream.answered(at: "result", answer)

    // Text mode printed the failure message on stdout.
    static func plain(_ output: ProcessRunner.Output) -> ProcessRunner.Output {
        .init(stdout: result(in: output.stdout)?.text ?? output.stdout, stderr: output.stderr, status: output.status)
    }
}

// `codex exec --json`: the last agent message once the turn completed.
enum CodexStream: CLIAnswerStream {
    static func answer(in stdout: String) -> String? {
        let events = CLIStream.events(in: stdout)
        guard events.contains(where: { $0["type"] as? String == "turn.completed" }) else { return nil }
        return events.compactMap { event -> String? in
            guard event["type"] as? String == "item.completed", let item = event["item"] as? [String: Any],
                  item["type"] as? String == "agent_message" else { return nil }
            return item["text"] as? String
        }.last
    }

    // Error events as the `ERROR:` lines plain mode writes to stderr.
    static func errorLines(in stdout: String) -> String {
        CLIStream.events(in: stdout).compactMap { event -> String? in
            guard event["type"] as? String == "error", let message = event["message"] as? String else { return nil }
            return "ERROR: " + message + "\n"
        }.joined()
    }

    static let isAnswered = CLIStream.answered(at: "turn.completed", answer)

    // Plain mode wrote its errors to stderr as `ERROR:` lines.
    static func plain(_ output: ProcessRunner.Output) -> ProcessRunner.Output {
        .init(stdout: "", stderr: errorLines(in: output.stdout) + output.stderr, status: output.status)
    }
}

// `grok --output-format streaming-json`: text fragments, complete at the end event.
enum GrokStream: CLIAnswerStream {
    static func answer(in stdout: String) -> String? {
        let events = CLIStream.events(in: stdout)
        guard events.contains(where: { $0["type"] as? String == "end" }) else { return nil }
        return events.compactMap { $0["type"] as? String == "text" ? $0["data"] as? String : nil }.joined()
    }

    static let isAnswered = CLIStream.answered(at: "end", answer)

    // Plain mode's stdout held only the answer, which a failure lacks.
    static func plain(_ output: ProcessRunner.Output) -> ProcessRunner.Output {
        .init(stdout: answer(in: output.stdout) ?? "", stderr: output.stderr, status: output.status)
    }
}

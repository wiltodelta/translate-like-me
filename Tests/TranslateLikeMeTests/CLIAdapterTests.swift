import Foundation
import XCTest
@testable import TranslateLikeMe

@MainActor
final class CLIAdapterTests: XCTestCase {
    private let replies: [Provider: String] = [
        .anthropic: #"{"type":"result","is_error":false,"result":"Hola"}"# + "\n",
        .openai: #"{"type":"item.completed","item":{"type":"agent_message","text":"Hola"}}"#
            + "\n" + #"{"type":"turn.completed"}"# + "\n",
        .grok: #"{"type":"text","data":"Hola"}"# + "\n" + #"{"type":"end"}"# + "\n",
        .antigravity: #"{"event":"result","result":{"status":"SUCCESS","response":"Hola"}}"# + "\n"
    ]

    func testSettingsReachEverySubprocessWithoutPuttingSelectionInArguments() async throws {
        let savedProvider = Settings.provider
        defer { Settings.provider = savedProvider }
        for provider in Provider.allCases where provider.usesCLI {
            let saved = Settings.harnessPick(for: provider)
            defer { Settings.setHarnessPick(saved, for: provider) }
            Settings.provider = provider
            let store = SettingsStore(refreshCatalog: { _ in })
            store.pick = .init(model: "synthetic-model", effort: "low")
            let invocation = CLIEngines.adapter(for: provider).invocation(
                system: "Translate only.", text: "SYNTHETIC_SELECTION", choice: store.resolution.choice)
            try await withCLI(reply: try XCTUnwrap(replies[provider])) { binary, directory in
                let answer = try await invocation.run(binary: binary.path, directory: directory)
                XCTAssertEqual(answer, "Hola")
                let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf:
                    directory.appendingPathComponent("receipt.json"))) as? [String: Any]
                let arguments = try XCTUnwrap(receipt?["arguments"] as? [String])
                let modelFlag = provider == .anthropic || provider == .antigravity ? "--model" : "-m"
                XCTAssertEqual(value(after: modelFlag, in: arguments), "synthetic-model")
                if provider == .openai {
                    XCTAssertTrue(arguments.contains("model_reasoning_effort=low"))
                    XCTAssertTrue(arguments.contains("--ignore-user-config"))
                    XCTAssertTrue(arguments.contains("--ephemeral"))
                    XCTAssertTrue(arguments.contains("features.shell_tool=false"))
                } else {
                    let flag = provider == .grok ? "--reasoning-effort" : "--effort"
                    XCTAssertEqual(value(after: flag, in: arguments), "low")
                }
                XCTAssertFalse(arguments.contains { $0.contains("SYNTHETIC_SELECTION") })
                XCTAssertTrue((receipt?["input"] as? String)?.contains("SYNTHETIC_SELECTION") == true)
                XCTAssertEqual(receipt?["hasAPIKey"] as? Bool, false)
                if provider == .grok { XCTAssertEqual(receipt?["grokMemory"] as? String, "0") }
                if provider == .anthropic {
                    XCTAssertTrue(arguments.contains("--no-session-persistence"))
                    XCTAssertEqual(value(after: "--tools", in: arguments), "")
                }
                if provider == .antigravity {
                    XCTAssertTrue(arguments.contains("--disable-slash-commands"))
                    XCTAssertEqual(value(after: "--agent", in: arguments), "translatelikeme")
                }
            }
        }
    }

    func testMalformedSuccessfulOutputIsNeverReturnedAsText() async throws {
        for provider in Provider.allCases where provider.usesCLI {
            let invocation = CLIEngines.adapter(for: provider).invocation(system: "Translate.", text: "Hello",
                                                                         choice: .init())
            try await withCLI(reply: "unknown protocol\n") { binary, directory in
                do {
                    _ = try await invocation.run(binary: binary.path, directory: directory)
                    XCTFail("Unrecognized output succeeded for \(provider)")
                } catch TranslatorError.failed { }
            }
        }
    }

    func testNonzeroExitPreservesQuotaDiagnosticsForEveryAdapter() async throws {
        for provider in Provider.allCases where provider.usesCLI {
            let invocation = CLIEngines.adapter(for: provider).invocation(system: "Translate.", text: "Hello",
                                                                         choice: .init())
            try await withCLI(reply: "", error: "Rate limit exceeded", status: 1) { binary, directory in
                do {
                    _ = try await invocation.run(binary: binary.path, directory: directory)
                    XCTFail("Quota failure succeeded for \(provider)")
                } catch is LimitReachedError { }
            }
        }
    }

    func testAntigravityNeverPassesStandaloneEffort() {
        let invocation = AntigravityAdapter().invocation(system: "Translate.", text: "Hello",
                                                         choice: .init(effort: "low"))
        XCTAssertFalse(invocation.arguments.contains("--effort"))
    }

    func testErrorEventsWithSuccessfulExitPreserveQuotaDiagnostics() async throws {
        let failures: [Provider: String] = [
            .anthropic: #"{"type":"result","is_error":true,"result":"Rate limit exceeded"}"# + "\n",
            .openai: #"{"type":"turn.failed","error":{"message":"Rate limit exceeded"}}"# + "\n",
            .grok: #"{"type":"error","message":"Rate limit exceeded"}"# + "\n"
        ]
        for (provider, reply) in failures {
            let invocation = CLIEngines.adapter(for: provider).invocation(system: "Translate.", text: "Hello",
                                                                         choice: .init())
            try await withCLI(reply: reply) { binary, directory in
                do {
                    _ = try await invocation.run(binary: binary.path, directory: directory)
                    XCTFail("Error event succeeded for \(provider)")
                } catch is LimitReachedError { }
            }
        }
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private func withCLI(reply: String, error: String = "", status: Int = 0,
                         body: (URL, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tlm-adapter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings: [String: Any] = ["reply": reply, "error": error, "status": status]
        try JSONSerialization.data(withJSONObject: settings).write(to: directory.appendingPathComponent("reply.json"))
        let binary = directory.appendingPathComponent("cli")
        try """
        #!/usr/bin/python3
        import json, os, sys
        from pathlib import Path
        receipt = {"arguments": sys.argv[1:], "input": sys.stdin.read(),
                   "hasAPIKey": any(os.environ.get(k) for k in
                      ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY"]),
                   "grokMemory": os.environ.get("GROK_MEMORY")}
        Path("receipt.json").write_text(json.dumps(receipt))
        reply = json.loads(Path("reply.json").read_text())
        sys.stdout.write(reply["reply"])
        sys.stderr.write(reply["error"])
        sys.exit(reply["status"])
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try await body(binary, directory)
    }
}

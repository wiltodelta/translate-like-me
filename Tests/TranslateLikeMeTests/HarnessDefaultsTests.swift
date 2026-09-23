import Foundation
import XCTest
@testable import TranslateLikeMe

final class HarnessDefaultsTests: XCTestCase {
    // Points `variable` at a throwaway directory holding `file`, so the test never
    // reads the real machine's CLI config.
    private func withConfigDir(_ variable: String, file: String, contents: String?, _ body: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("harness-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let contents {
            try? contents.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        setenv(variable, dir.path, 1)
        defer {
            unsetenv(variable)
            try? FileManager.default.removeItem(at: dir)
        }
        body()
    }

    // Shape of the real ~/.codex/config.toml on 2026-09-23, plus a table whose
    // `model` key must not win.
    func testCodexReadsTopLevelModelAndEffort() {
        let toml = """
        model = "gpt-5.6-sol"
        model_reasoning_effort = "medium"
        # a comment
        [profiles.fast]
        model = "gpt-6-luna"
        """
        withConfigDir("CODEX_HOME", file: "config.toml", contents: toml) {
            XCTAssertEqual(HarnessDefaults.codex(), .init(model: "gpt-5.6-sol", effort: "medium"))
        }
    }

    func testCodexWithoutConfigUsesTheCLIDefault() {
        withConfigDir("CODEX_HOME", file: "config.toml", contents: nil) {
            XCTAssertEqual(HarnessDefaults.codex(), .init(model: nil, effort: nil))
        }
    }

    func testClaudeReadsModelAndEffortLevel() {
        withConfigDir("CLAUDE_CONFIG_DIR", file: "settings.json",
                      contents: #"{"model": "opus", "effortLevel": "medium", "hooks": {}}"#) {
            XCTAssertEqual(HarnessDefaults.claude(), .init(model: "opus", effort: "medium"))
        }
    }

    // The real settings.json on 2026-09-23 sets an effort but no model.
    func testClaudeWithoutModelLeavesItToTheCLI() {
        withConfigDir("CLAUDE_CONFIG_DIR", file: "settings.json", contents: #"{"effortLevel": "medium"}"#) {
            XCTAssertEqual(HarnessDefaults.claude(), .init(model: nil, effort: "medium"))
        }
    }

    func testTOMLParserReadsBothQuoteStylesAndSkipsNonStrings() {
        let values = HarnessDefaults.topLevelTOMLStrings("""
        approval_policy = "never"  # inline comment
        model = 'gpt-6-sol'
        max_tokens = 100
        """)
        XCTAssertEqual(values["approval_policy"], "never")
        XCTAssertEqual(values["model"], "gpt-6-sol")
        XCTAssertNil(values["max_tokens"])
    }

    func testCodexEmptyModelFallsBackToTheCLIDefault() {
        withConfigDir("CODEX_HOME", file: "config.toml", contents: #"model = """#) {
            XCTAssertEqual(HarnessDefaults.codex(), .init(model: nil, effort: nil))
        }
    }

    // A model for a custom provider would fail against the default one, which is
    // all an isolated run can reach, so only the effort is kept.
    func testCodexSkipsModelOfAnotherProvider() {
        let toml = """
        model = "llama3"
        model_provider = "ollama"
        model_reasoning_effort = "high"
        """
        withConfigDir("CODEX_HOME", file: "config.toml", contents: toml) {
            XCTAssertEqual(HarnessDefaults.codex(), .init(model: nil, effort: "high"))
        }
    }

    func testClaudeSkipsModelWhenSettingsRerouteTheProvider() {
        let json = #"{"model": "us.anthropic.claude-x", "effortLevel": "low", "env": {"CLAUDE_CODE_USE_BEDROCK": "1"}}"#
        withConfigDir("CLAUDE_CONFIG_DIR", file: "settings.json", contents: json) {
            XCTAssertEqual(HarnessDefaults.claude(), .init(model: nil, effort: "low"))
        }
    }
}

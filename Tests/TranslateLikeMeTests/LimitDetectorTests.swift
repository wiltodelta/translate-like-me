import XCTest
@testable import TranslateLikeMe

final class LimitDetectorTests: XCTestCase {
    // Captured 2026-08-17 from real exhausted-subscription failures on this
    // machine (claude -p stdout; codex exec stderr).
    private let claudeWeekly =
        "You've hit your weekly limit · resets Aug 19 at 10pm (America/Los_Angeles)"
    private let codexUsageLine =
        "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage "
            + "to purchase more credits or try again at Aug 19th, 2026 8:29 PM."
    private let codexStderr = """
        OpenAI Codex v0.147.0
        --------
        workdir: /Users/wiltodelta/Documents/GitHub/translate-like-me
        model: gpt-5.4-mini
        provider: openai
        approval: never
        sandbox: read-only
        reasoning effort: low
        reasoning summaries: none
        session id: 01a011e3-c3de-7d90-a9f2-f694c5b3d9c9
        --------
        user
        Translate to Russian: hi
        ERROR: You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Aug 19th, 2026 8:29 PM.
        ERROR: You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Aug 19th, 2026 8:29 PM.
        """

    func testClaudeWeeklyLimit() {
        XCTAssertEqual(LimitDetector.message(in: claudeWeekly), claudeWeekly)
    }

    func testClaudeFiveHourVariant() {
        let line = "You've hit your 5-hour limit · resets at 3pm (America/Los_Angeles)"
        XCTAssertEqual(LimitDetector.message(in: line), line)
    }

    func testCodexStderrYieldsSingleCleanedLine() {
        XCTAssertEqual(LimitDetector.message(in: codexStderr), codexUsageLine)
    }

    func testCodexStderrOnCombinedStreamsWithEmptyStderr() {
        XCTAssertEqual(LimitDetector.message(in: "\n" + codexStderr), codexUsageLine)
    }

    func testAPIQuotaBodies() {
        XCTAssertEqual(
            LimitDetector.message(in: "This request would exceed your monthly text-token limit."),
            "This request would exceed your monthly text-token limit.")
        XCTAssertEqual(
            LimitDetector.message(in: "You exceeded your current quota, please check your plan and billing details."),
            "You exceeded your current quota, please check your plan and billing details.")
    }

    func testNonLimitFailuresAreNotMatched() {
        XCTAssertNil(LimitDetector.message(in: "Engine exited with status 1."))
        XCTAssertNil(LimitDetector.message(in: "Error: connection reset by peer"))
        XCTAssertNil(LimitDetector.message(in: ""))
        XCTAssertNil(LimitDetector.message(in: "The plan includes unlimited translations"))
    }
}

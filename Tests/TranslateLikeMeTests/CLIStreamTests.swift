import Foundation
import XCTest
@testable import TranslateLikeMe

// Event shapes captured 2026-10-22: claude 2.1.308, codex-cli 0.163.0, grok 1.0.67.
final class CLIStreamTests: XCTestCase {
    private let claudeInit = #"{"type":"system","subtype":"init","model":"claude-opus-5-5"}"#
    private let claudeSuccess = #"{"type":"result","subtype":"success","is_error":false,"result":"Hi, let's talk."}"#
    private let claudeFailure = #"{"type":"result","subtype":"success","is_error":true,"#
        + #""result":"There's an issue with the selected model."}"#

    func testClaudeAnswerOrTheTextModeFailureMessage() {
        XCTAssertEqual(ClaudeStream.answer(in: lines(claudeInit, claudeSuccess)), "Hi, let's talk.")
        XCTAssertEqual(ClaudeStream.result(in: lines(claudeInit, claudeFailure)),
                       .init(text: "There's an issue with the selected model.", isError: true))
        XCTAssertNil(ClaudeStream.answer(in: lines(claudeInit, claudeFailure)), "A failure waits for the exit status")
        XCTAssertNil(ClaudeStream.answer(in: lines(claudeInit)))
        XCTAssertNil(ClaudeStream.answer(in: claudeInit + "\n" + claudeSuccess), "A partial line can still grow")
        XCTAssertNil(ClaudeStream.answer(in: "Not logged in · Please run /login\n"))
    }

    func testCodexAnswerOnlyAfterTheTurnCompletes() {
        let message = #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Hi."}}"#
        let started = #"{"type":"turn.started"}"#
        let completed = #"{"type":"turn.completed","usage":{"input_tokens":28997,"output_tokens":6}}"#
        XCTAssertNil(CodexStream.answer(in: lines(started, message)))
        XCTAssertEqual(CodexStream.answer(in: lines(started, message, completed)), "Hi.")
    }

    func testCodexErrorsBecomeThePlainModeErrorLines() {
        let warning = #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata"}}"#
        let error = #"{"type":"error","message":"{\"type\":\"error\",\"status\":400}"}"#
        let failed = #"{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400}"}}"#
        let stdout = lines(warning, error, failed)
        XCTAssertNil(CodexStream.answer(in: stdout))
        XCTAssertEqual(CodexStream.errorLines(in: stdout), #"ERROR: {"type":"error","status":400}"# + "\n")
    }

    func testGrokJoinsTextFragmentsAtTheEndEvent() {
        let thought = #"{"type":"thought","data":"Translating."}"#
        let first = #"{"type":"text","data":"Hi"}"#, second = #"{"type":"text","data":"."}"#
        let end = #"{"type":"end","stopReason":"end_turn"}"#
        XCTAssertNil(GrokStream.answer(in: lines(thought, first, second)))
        XCTAssertEqual(GrokStream.answer(in: lines(thought, first, second, end)), "Hi.")
        XCTAssertNil(GrokStream.answer(in: lines(#"{"type":"error","message":"Couldn't set model"}"#)))
    }

    func testAnsweredOnlyAtACompleteSuccessfulFinalEvent() {
        XCTAssertFalse(ClaudeStream.isAnswered(Data(lines(claudeInit).utf8)))
        XCTAssertTrue(ClaudeStream.isAnswered(Data(lines(claudeInit, claudeSuccess).utf8)))
        XCTAssertFalse(ClaudeStream.isAnswered(Data((claudeInit + "\n" + claudeSuccess).utf8)), "A partial line")
        XCTAssertFalse(ClaudeStream.isAnswered(Data(lines(claudeInit, claudeFailure).utf8)), "A failure waits")
        XCTAssertTrue(GrokStream.isAnswered(Data(lines(#"{"type":"text","data":"Hi"}"#, #"{"type":"end"}"#).utf8)))
        XCTAssertFalse(CodexStream.isAnswered(Data(lines(#"{"type":"turn.started"}"#).utf8)))
    }

    private func lines(_ events: String...) -> String { events.map { $0 + "\n" }.joined() }
}

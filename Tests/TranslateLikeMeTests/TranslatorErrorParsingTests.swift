import XCTest
@testable import TranslateLikeMe

final class TranslatorErrorParsingTests: XCTestCase {
    // Captured 2026-09-22 (codex-cli 0.156.0, `-m gpt-5.4-mini` on a ChatGPT
    // account): stderr tail, exit 1, the JSON line printed twice.
    private let codexStderr = """
        codex
        ERROR: {"type":"error","status":400,"error":{"type":"invalid_request_error",\
        "message":"The 'gpt-5.4-mini' model is not supported when using Codex with a ChatGPT account."}}
        ERROR: {"type":"error","status":400,"error":{"type":"invalid_request_error",\
        "message":"The 'gpt-5.4-mini' model is not supported when using Codex with a ChatGPT account."}}
        """

    func testCodexRepeatedJSONErrorLineYieldsMessage() {
        XCTAssertEqual(
            JSONErrorMessage.extract(from: codexStderr),
            "The 'gpt-5.4-mini' model is not supported when using Codex with a ChatGPT account.")
    }

    func testPrettyPrintedObjectAndBracesInStrings() {
        let text = """
            Error: {
              "error": {"message": "bad {brace} inside", "type": "server_error"}
            }
            """
        XCTAssertEqual(JSONErrorMessage.extract(from: text), "bad {brace} inside")
    }

    func testObjectAfterUnparseableProseBraces() {
        let text = "note {not json} then {\"message\":\"real\"}"
        XCTAssertEqual(JSONErrorMessage.extract(from: text), "real")
    }

    func testAPIStyleErrorDotMessage() {
        let text = "HTTP 500: {\"error\":{\"message\":\"overloaded_error\",\"type\":\"server_error\"}}"
        XCTAssertEqual(JSONErrorMessage.extract(from: text), "overloaded_error")
    }

    func testTopLevelMessage() {
        XCTAssertEqual(JSONErrorMessage.extract(from: "{\"message\":\"rate limited\"}"), "rate limited")
    }

    func testNonJSONTextYieldsNil() {
        XCTAssertNil(JSONErrorMessage.extract(from: "Engine exited with status 1."))
        XCTAssertNil(JSONErrorMessage.extract(from: ""))
        XCTAssertNil(JSONErrorMessage.extract(from: "{not json"))
    }
}

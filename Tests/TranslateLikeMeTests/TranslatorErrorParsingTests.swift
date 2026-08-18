import XCTest
@testable import TranslateLikeMe

final class TranslatorErrorParsingTests: XCTestCase {
    // Captured 2026-08-17: opencode prints failures as `Error: {json}` on
    // stderr (ANSI-colored prefix), with the human text under data.message.
    private let opencodeStderr = "\u{1B}[91m\u{1B}[1mError: \u{1B}[0m{\n"
        + "  \"name\": \"UnknownError\",\n"
        + "  \"data\": {\n"
        + "    \"message\": \"Unexpected server error. Check server logs for details.\",\n"
        + "    \"ref\": \"err_f8255830\"\n"
        + "  }\n"
        + "}\n"

    func testOpencodeJSONErrorYieldsDataMessage() {
        XCTAssertEqual(
            JSONErrorMessage.extract(from: opencodeStderr),
            "Unexpected server error. Check server logs for details.")
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

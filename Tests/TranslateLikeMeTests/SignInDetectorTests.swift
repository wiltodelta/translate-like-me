import XCTest
@testable import TranslateLikeMe

// UX audit 2026-09-28 (UX-T03): a signed-out CLI's own instructions are replaced by
// the status menu's one-line fix.
final class SignInDetectorTests: XCTestCase {
    func testRecognizesSignedOutCLIs() {
        let grok = """
        Error: Not signed in. To authenticate without a browser, run:
        grok login --device-code
        Alternatively, set the XAI_API_KEY environment variable or run `grok login` on a machine with a browser.
        """
        XCTAssertTrue(SignInDetector.matches(grok))
        XCTAssertTrue(SignInDetector.matches("You are not authenticated."))
        XCTAssertTrue(SignInDetector.matches("Error: Not logged in"))
    }

    func testLeavesOtherFailuresAlone() {
        XCTAssertFalse(SignInDetector.matches("API Error: 529 Overloaded. Try again in a few minutes."))
        XCTAssertFalse(SignInDetector.matches("You've hit your weekly limit · resets Oct 2 at 10pm"))
    }

    func testPopupAndMenuShareOneSentence() {
        let error = TranslatorError.notSignedIn(.grok)
        XCTAssertEqual(error.errorDescription, "Not signed in to Grok. Run grok login in Terminal.")
        XCTAssertEqual(error.errorDescription, Provider.grok.notSignedInHint)
    }
}

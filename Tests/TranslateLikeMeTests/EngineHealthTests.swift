import XCTest
@testable import TranslateLikeMe

final class EngineHealthTests: XCTestCase {
    func testSignInCheckDecidesOnlyWhenItFails() {
        XCTAssertNil(EngineHealth(EngineStatus.Readiness.ready))
        XCTAssertEqual(EngineHealth(.notInstalled), .notInstalled)
        XCTAssertEqual(EngineHealth(.notLoggedIn), .notSignedIn)
    }

    func testTestTranslationFailuresKeepTheirKind() {
        XCTAssertEqual(EngineHealth(LimitReachedError(message: "Resets at 5pm")), .limitReached("Resets at 5pm"))
        XCTAssertEqual(EngineHealth(TranslatorError.notSignedIn(.grok)), .notSignedIn)
        XCTAssertEqual(EngineHealth(TranslatorError.binaryNotFound("grok")), .notInstalled)
        XCTAssertEqual(EngineHealth(TranslatorError.failed("Model not found")), .failed("Model not found"))
    }
}

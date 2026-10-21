import XCTest
@testable import TranslateLikeMe

final class EngineHealthTests: XCTestCase {
    func testSignInCheckDecidesOnlyWhenItFails() {
        XCTAssertNil(EngineHealth(EngineStatus.Readiness.ready))
        XCTAssertEqual(EngineHealth(.notInstalled), .notInstalled)
        XCTAssertEqual(EngineHealth(.notLoggedIn), .notSignedIn)
    }

    func testLocalReadinessRejectsAnInstalledModelThatDoesNotFit() {
        XCTAssertEqual(EngineStatus.localReadiness(model: .translateGemma12B, installed: true,
                                                   physicalMemory: 8 << 30),
                       .failed(LocalModelError.insufficientMemory(.translateGemma12B).localizedDescription))
        XCTAssertEqual(EngineStatus.localReadiness(model: .gemma4E2B, installed: true,
                                                   physicalMemory: 8 << 30), .ready)
        XCTAssertEqual(EngineStatus.localReadiness(model: .gemma4E2B, installed: false,
                                                   physicalMemory: 8 << 30), .notInstalled)
    }

    func testTestTranslationFailuresKeepTheirKind() {
        XCTAssertEqual(EngineHealth(LimitReachedError(message: "Resets at 5pm")), .limitReached("Resets at 5pm"))
        XCTAssertEqual(EngineHealth(TranslatorError.notSignedIn(.grok)), .notSignedIn)
        XCTAssertEqual(EngineHealth(TranslatorError.binaryNotFound("grok")), .notInstalled)
        XCTAssertEqual(EngineHealth(LocalModelError.notDownloaded(.gemma4E2B)), .notInstalled)
        XCTAssertEqual(EngineHealth(TranslatorError.failed("Model not found")), .failed("Model not found"))
    }
}

import XCTest
@testable import TranslateLikeMe

// UpdateChecker is @MainActor, so its static members are main-actor isolated.
@MainActor
final class UpdateCheckerTests: XCTestCase {
    func testNewerPatchMinorMajor() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1", than: "1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0", than: "1.9"))
    }

    func testEqualIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.2", than: "1.2"))
        XCTAssertFalse(UpdateChecker.isNewer("1.2.0", than: "1.2"))
    }

    func testOlderIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0.1"))
    }

    func testNumericNotLexicographic() {
        // 1.10 is newer than 1.9 numerically; a string compare would say otherwise.
        XCTAssertTrue(UpdateChecker.isNewer("1.10", than: "1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9", than: "1.10"))
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0.0"))
    }
}

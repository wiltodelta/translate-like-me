import XCTest
@testable import TranslateLikeMe

final class LanguagesTests: XCTestCase {
    func testSettingADistinctLanguageKeepsTheOtherSide() {
        let pair = Languages.pair(settingFirst: true, to: "de", current: ("ru", "en"))
        XCTAssertEqual(pair.first, "de")
        XCTAssertEqual(pair.second, "en")
    }

    func testPickingTheOtherSidesLanguageMovesThatSide() {
        // "en" is first in the list, so the displaced side falls to the next one.
        let second = Languages.pair(settingFirst: false, to: "ru", current: ("ru", "en"))
        XCTAssertEqual(second.second, "ru")
        XCTAssertEqual(second.first, "en")

        let first = Languages.pair(settingFirst: true, to: "en", current: ("ru", "en"))
        XCTAssertEqual(first.first, "en")
        XCTAssertEqual(first.second, "ru")
    }
}

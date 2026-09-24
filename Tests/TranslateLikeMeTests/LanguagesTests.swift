import Carbon
import XCTest
@testable import TranslateLikeMe

final class LanguagesTests: XCTestCase {
    private func pair(_ first: String, _ second: String) -> LanguagePair {
        LanguagePair(first: first, second: second, shortcut: nil)
    }

    // MARK: - Editing a pair

    func testSettingADistinctLanguageKeepsTheOtherSide() {
        let edited = Languages.setting(pair("ru", "en"), first: true, to: "de")
        XCTAssertEqual([edited.first, edited.second], ["de", "en"])
    }

    func testPickingTheOtherSidesLanguageSwapsTheSides() {
        let second = Languages.setting(pair("ru", "en"), first: false, to: "ru")
        XCTAssertEqual([second.first, second.second], ["en", "ru"])
        let first = Languages.setting(pair("ru", "en"), first: true, to: "en")
        XCTAssertEqual([first.first, first.second], ["en", "ru"])
    }

    func testNewPairKeepsTheFirstLanguageAndSkipsTakenPartners() {
        let added = Languages.newPair(after: [pair("ru", "en")])
        XCTAssertEqual(added.first, "ru")
        XCTAssertEqual(added.second, "es") // "en" is taken, "ru" is itself
        XCTAssertNil(added.shortcut)
        XCTAssertEqual(Languages.newPair(after: [pair("ru", "en"), added]).second, "fr")
    }

    // MARK: - System languages

    func testPreferredIdentifiersMapToTheLongestListedCode() {
        XCTAssertEqual(Languages.code(forPreferred: "ru-US"), "ru")
        XCTAssertEqual(Languages.code(forPreferred: "zh-Hant-TW"), "zh-Hant")
        XCTAssertEqual(Languages.code(forPreferred: "pt-PT"), "pt-PT")
        XCTAssertEqual(Languages.code(forPreferred: "pt"), "pt-BR")
        XCTAssertEqual(Languages.code(forPreferred: "zh"), "zh-Hans")
        XCTAssertNil(Languages.code(forPreferred: "xx-YY"))
    }

    func testDefaultPairFollowsTheSystemLanguages() {
        func codes(_ preferred: [String]) -> [String] {
            let made = Languages.defaultPair(preferred: preferred)
            return [made.first, made.second]
        }
        XCTAssertEqual(codes(["ru-US", "en-US"]), ["ru", "en"])
        XCTAssertEqual(codes(["de-DE"]), ["de", "en"])
        XCTAssertEqual(codes(["en-US", "en-GB", "fr-FR"]), ["en", "fr"]) // duplicates collapse
        XCTAssertEqual(codes(["en-US"]), ["en", "es"])
        XCTAssertEqual(codes(["xx"]), ["en", "es"])
        XCTAssertEqual(Languages.defaultPair(preferred: ["ru"]).shortcut, Languages.defaultShortcut)
    }

    // MARK: - Migration from the single pair

    private func withSuite(_ body: (UserDefaults) -> Void) {
        let name = "LanguagesTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        body(suite)
    }

    func testNewUserHasNoLegacyPair() {
        withSuite { XCTAssertNil(Settings.legacyPair(in: $0)) }
    }

    // An earlier version that ran with its defaults stored no language keys.
    func testEarlierRunWithDefaultsBecomesRussianEnglishOnOptionCommandF() {
        withSuite { suite in
            suite.set(true, forKey: "didCompleteFirstRun")
            let legacy = Settings.legacyPair(in: suite)
            XCTAssertEqual(legacy?.first, "ru")
            XCTAssertEqual(legacy?.second, "en")
            XCTAssertEqual(legacy?.shortcut, Languages.defaultShortcut)
        }
    }

    func testStoredLanguagesAndShortcutCarryOverWithOldCodesNormalized() {
        withSuite { suite in
            suite.set("zh", forKey: "languageA")
            suite.set("pt", forKey: "languageB")
            suite.set(17, forKey: "replaceKeyCode")
            suite.set(Int(controlKey), forKey: "replaceModifiers")
            let legacy = Settings.legacyPair(in: suite)
            XCTAssertEqual(legacy?.first, "zh-Hans")
            XCTAssertEqual(legacy?.second, "pt-BR")
            XCTAssertEqual(legacy?.shortcut, KeyCombo(keyCode: 17, modifiers: Int(controlKey)))
        }
    }

    // MARK: - Prompt

    func testPromptNamesThePairAndSendsOtherLanguagesToTheFirst() {
        let prompt = Translator.systemPrompt(pair: pair("ru", "pt-BR"), style: "")
        XCTAssertTrue(prompt.contains("between Russian and Portuguese (Brazil)"))
        XCTAssertTrue(prompt.contains("if the input is Russian, the output is Portuguese (Brazil)"))
        XCTAssertTrue(prompt.contains("A third-language input is never translated into Portuguese (Brazil)."))
    }
}

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

    func testFirstPairAddedStartsFromTheSystemLanguagesOnTheDefaultShortcut() {
        let added = Languages.newPair(after: [], preferred: ["de-DE", "ru-RU"])
        XCTAssertEqual([added.first, added.second], ["de", "ru"])
        XCTAssertEqual(added.shortcut, Languages.defaultShortcut)
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

    // A new user sets the pairs up in onboarding; nothing is added for them.
    func testNewUserStartsWithNoPairs() {
        withSuite { XCTAssertEqual(Settings.initialPairs(in: $0), []) }
    }

    func testEarlierRunKeepsItsPairWhenNoneAreStored() {
        withSuite { suite in
            suite.set("de", forKey: "languageA")
            XCTAssertEqual(Settings.initialPairs(in: suite).map(\.first), ["de"])
        }
    }

    // Removing every pair is stored as none, not read back as "nothing stored".
    func testNoPairsStoredStaysNoPairs() {
        withSuite { suite in
            suite.set(true, forKey: "didCompleteFirstRun")
            Settings.storePairs([], in: suite)
            XCTAssertEqual(Settings.storedPairs(in: suite), [])
        }
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

    // MARK: - Styles moving into the pairs

    private func stored(_ pairs: [LanguagePair], in suite: UserDefaults) {
        Settings.storePairs(pairs, in: suite)
    }

    private func styles(in suite: UserDefaults) -> [String] {
        (Settings.storedPairs(in: suite) ?? []).map(\.style)
    }

    func testPairStoredWithoutAStyleDecodesAsPlain() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","first":"ru","second":"en","#
            + #""shortcut":{"keyCode":3,"modifiers":2304}}]"#
        let pairs = try JSONDecoder().decode([LanguagePair].self, from: Data(json.utf8))
        XCTAssertEqual(pairs.first?.style, "")
        XCTAssertEqual(pairs.first?.shortcut, KeyCombo(keyCode: 3, modifiers: 2304))
    }

    func testOneStyleForAllMovesIntoEveryPair() {
        withSuite { suite in
            stored([pair("ru", "en"), pair("ru", "es")], in: suite)
            suite.set("Casual.", forKey: "style")
            Settings.moveStyleIntoPairs(in: suite)
            XCTAssertEqual(styles(in: suite), ["Casual.", "Casual."])
            XCTAssertNil(suite.object(forKey: "style"))
        }
    }

    // A pair left plain next to a styled one is for someone else's text.
    func testPairsWithTheirOwnStylesKeepThemAndThePlainOneStaysPlain() {
        withSuite { suite in
            var own = pair("ru", "en")
            own.style = "Formal."
            stored([own, pair("ru", "en")], in: suite)
            suite.set("Casual.", forKey: "style")
            Settings.moveStyleIntoPairs(in: suite)
            XCTAssertEqual(styles(in: suite), ["Formal.", ""])
            XCTAssertNil(suite.object(forKey: "style"))
        }
    }

    func testEmptyStyleForAllLeavesThePairsPlain() {
        withSuite { suite in
            stored([pair("ru", "en")], in: suite)
            suite.set("  ", forKey: "style")
            Settings.moveStyleIntoPairs(in: suite)
            XCTAssertEqual(styles(in: suite), [""])
            XCTAssertNil(suite.object(forKey: "style"))
        }
    }

    // MARK: - Prompt

    func testPromptCarriesOnlyItsOwnPairsStyle() {
        var styled = pair("ru", "en")
        styled.style = "Casual, short sentences."
        XCTAssertTrue(Translator.systemPrompt(pair: styled).contains("in this voice"))
        XCTAssertTrue(Translator.systemPrompt(pair: styled).contains("Casual, short sentences."))
        styled.style = " \n"
        XCTAssertFalse(Translator.systemPrompt(pair: styled).contains("in this voice"))
    }

    func testPromptNamesThePairAndSendsOtherLanguagesToTheFirst() {
        let prompt = Translator.systemPrompt(pair: pair("ru", "pt-BR"))
        XCTAssertTrue(prompt.contains("between Russian and Portuguese (Brazil)"))
        XCTAssertTrue(prompt.contains("if the input is Russian, the output is Portuguese (Brazil)"))
        XCTAssertTrue(prompt.contains("A third-language input is never translated into Portuguese (Brazil)."))
    }
}

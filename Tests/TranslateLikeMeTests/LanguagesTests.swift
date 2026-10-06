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

    func testNewPairTakesTheNextSuggestionTheFirstLanguageIsNotPairedWith() {
        let added = Languages.newPair(after: [pair("ru", "en")], suggestions: ["ru", "en", "de", "fr"])
        XCTAssertEqual([added.first, added.second], ["ru", "de"])
        XCTAssertNil(added.shortcut)
        let third = Languages.newPair(after: [pair("ru", "en"), added], suggestions: ["ru", "en", "de", "fr"])
        XCTAssertEqual(third.second, "fr")
    }

    // Nothing left to suggest: the second language waits for the user instead
    // of being picked from the list.
    func testNewPairLeavesTheSecondUnchosenWhenSuggestionsRunOut() {
        let added = Languages.newPair(after: [pair("en", "ru")], suggestions: ["en", "ru"])
        XCTAssertEqual(added.second, "")
        XCTAssertFalse(added.isComplete)
    }

    func testFirstPairAddedIsTheFirstTwoSuggestionsOnTheDefaultShortcut() {
        let added = Languages.newPair(after: [], suggestions: ["de", "ru"])
        XCTAssertEqual([added.first, added.second], ["de", "ru"])
        XCTAssertEqual(added.shortcut, Languages.defaultShortcut)
    }

    // An English Mac with a U.S. layout in the US says nothing about a second
    // language.
    func testFirstPairOnAnEnglishOnlyMacLeavesTheSecondUnchosen() {
        let made = Languages.newPair(after: [], suggestions: Languages.suggestions(
            preferred: ["en-US"], keyboards: ["en"], region: "US"))
        XCTAssertEqual([made.first, made.second], ["en", ""])
    }

    // MARK: - System languages

    func testListCoversMacOSLanguagesWithScriptsAndPortugueseByRegion() {
        let codes = Set(Languages.all.map(\.code))
        XCTAssertGreaterThan(codes.count, 250)
        for code in ["en", "ru", "uk", "ka", "hy", "sw", "zh-Hans", "zh-Hant", "sr-Cyrl", "sr-Latn", "pt-BR", "pt-PT"] {
            XCTAssertTrue(codes.contains(code), code)
        }
        XCTAssertFalse(codes.contains("pt"))
        XCTAssertFalse(codes.contains("zh"))
        XCTAssertFalse(codes.contains("ur-Aran")) // a style of the Arabic script
        XCTAssertEqual(Languages.name(for: "ka"), "Georgian")
        XCTAssertEqual(Languages.all.map(\.name), Languages.all.map(\.name).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
    }

    // Every language a pair stored before the full list keeps its code.
    func testCodesFromTheCuratedListStillExist() {
        let codes = Set(Languages.all.map(\.code))
        for code in ["en", "ru", "es", "fr", "de", "it", "pt-BR", "pt-PT", "nl", "pl", "uk", "tr", "ar", "he",
                     "hi", "zh-Hans", "zh-Hant", "ja", "ko", "vi", "th", "id", "sv", "no", "da", "fi", "cs",
                     "el", "ro", "hu"] {
            XCTAssertTrue(codes.contains(code), code)
        }
    }

    func testPreferredIdentifiersMapToTheLongestListedCode() {
        XCTAssertEqual(Languages.code(forPreferred: "ru-US"), "ru")
        XCTAssertEqual(Languages.code(forPreferred: "zh-Hant-TW"), "zh-Hant")
        XCTAssertEqual(Languages.code(forPreferred: "pt-PT"), "pt-PT")
        XCTAssertEqual(Languages.code(forPreferred: "pt"), "pt-BR")
        XCTAssertEqual(Languages.code(forPreferred: "zh"), "zh-Hans")
        XCTAssertEqual(Languages.code(forPreferred: "sr"), "sr-Cyrl") // its default script
        XCTAssertEqual(Languages.code(forPreferred: "sr_Latn"), "sr-Latn") // keyboard spelling
        XCTAssertNil(Languages.code(forPreferred: "xx-YY"))
    }

    func testSuggestionsGoSystemThenKeyboardsThenRegionThenEnglish() {
        XCTAssertEqual(Languages.suggestions(preferred: ["en-US", "ru-US"], keyboards: [], region: "US"),
                       ["en", "ru"])
        // One system language: a Russian layout says the second.
        XCTAssertEqual(Languages.suggestions(preferred: ["en-US"], keyboards: ["en", "ru"], region: "US"),
                       ["en", "ru"])
        // Neither: the region's language.
        XCTAssertEqual(Languages.suggestions(preferred: ["en-DE"], keyboards: ["en"], region: "DE"),
                       ["en", "de"])
        // A non-English Mac gets English last.
        XCTAssertEqual(Languages.suggestions(preferred: ["ru-RU"], keyboards: ["ru"], region: "RU"),
                       ["ru", "en"])
        XCTAssertEqual(Languages.suggestions(preferred: ["en-US", "en-GB"], keyboards: ["xx"], region: nil),
                       ["en"]) // repeats and unlisted codes collapse
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

import Carbon
import XCTest
@testable import TranslateLikeMe

@MainActor
final class FirstRunRecommendationsTests: XCTestCase {
    private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "FirstRunRecommendationsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testFreshSeedUsesEvidenceAndProvidesNeutralImprovementWithoutShortcutCollisions() throws {
        try withSuite { defaults in
            FirstRunRecommendations.apply(in: defaults, suggestions: Languages.suggestions(
                preferred: ["ru-RU"], keyboards: ["en", "ru"]), physicalMemory: 16 << 30)
            let pairs = try XCTUnwrap(Settings.storedPairs(in: defaults))
            XCTAssertEqual(pairs.map(\.first), ["ru"])
            XCTAssertEqual(pairs.map(\.second), ["en"])
            let data = try XCTUnwrap(defaults.data(forKey: "rewritePresets"))
            let presets = try JSONDecoder().decode([RewritePreset].self, from: data)
            XCTAssertEqual(presets.count, 1)
            XCTAssertEqual(presets[0].trimmedStyle, "")
            XCTAssertNotNil(presets[0].shortcut)
            XCTAssertNotEqual(presets[0].shortcut, pairs[0].shortcut)
            XCTAssertFalse(Shortcut.isOptionOnly(try XCTUnwrap(presets[0].shortcut)))
            XCTAssertNil(defaults.object(forKey: "dictationEnabled"))
            XCTAssertEqual(defaults.string(forKey: "provider"), Provider.local.rawValue)
            XCTAssertTrue(defaults.bool(forKey: "automaticallySelectedProvider"))
            XCTAssertEqual(defaults.string(forKey: "localModel"), LocalModel.gemma4E2B.rawValue)
            XCTAssertEqual(defaults.string(forKey: "dictationModel"), DictationModel.turbo.rawValue)
        }
    }

    func testOneOrNoLanguageDoesNotInventASecond() {
        for suggestions in [["ru"], []] {
            withSuite { defaults in
                FirstRunRecommendations.apply(in: defaults, suggestions: suggestions)
                let pairs = Settings.storedPairs(in: defaults) ?? []
                XCTAssertEqual(pairs.count, suggestions.count)
                XCTAssertFalse(pairs.contains(where: \.isComplete))
                XCTAssertTrue(pairs.allSatisfy { $0.second.isEmpty })
            }
        }
    }

    func testUserEditsAndRemovalsSurviveAnotherLaunch() {
        withSuite { defaults in
            FirstRunRecommendations.apply(in: defaults, suggestions: ["en", "de"])
            Settings.storePairs([], in: defaults)
            defaults.set(Data("[]".utf8), forKey: "rewritePresets")
            FirstRunRecommendations.apply(in: defaults, suggestions: ["ru", "en"])
            XCTAssertEqual(Settings.storedPairs(in: defaults), [])
            XCTAssertEqual(defaults.data(forKey: "rewritePresets"), Data("[]".utf8))
        }
    }

    func testExistingProfilesIncludingUnfinishedOnboardingAreUntouched() {
        for key in ["languagePairs", "rewritePresets", "didCompleteFirstRun", "languageA", "provider",
                    "dictationModel", "dictationShortcut", "dictationMicrophone", "style", "localModel"] {
            withSuite { defaults in
                // Even a stored empty or false value is authoritative.
                defaults.set(Data("[]".utf8), forKey: key)
                FirstRunRecommendations.apply(in: defaults, suggestions: ["en", "de"])
                XCTAssertEqual(defaults.data(forKey: key), Data("[]".utf8), key)
                for other in ["languagePairs", "rewritePresets"] where other != key {
                    XCTAssertNil(defaults.object(forKey: other), key)
                }
            }
        }
    }

    func testValidCustomProfileKeepsStylesShortcutsAndModelPicks() throws {
        try withSuite { defaults in
            let shortcut = KeyCombo(keyCode: 38, modifiers: Int(cmdKey | optionKey))
            let pairs = [LanguagePair(first: "ja", second: "de", shortcut: shortcut, style: "Keep technical terms.")]
            let presets = [RewritePreset(name: "Custom", shortcut: Languages.defaultShortcut, style: "Brief.")]
            Settings.storePairs(pairs, in: defaults)
            let encoded = try JSONEncoder().encode(presets)
            defaults.set(encoded, forKey: "rewritePresets")
            defaults.set("local", forKey: "provider")
            defaults.set("gemma-4-e2b", forKey: "localModel")
            defaults.set("qwen3ASR", forKey: "dictationModel")
            defaults.set("synthetic-model", forKey: "harnessModel.openai")
            FirstRunRecommendations.apply(in: defaults, suggestions: ["en", "ru"])
            XCTAssertEqual(Settings.storedPairs(in: defaults), pairs)
            XCTAssertEqual(defaults.data(forKey: "rewritePresets"), encoded)
            XCTAssertEqual(defaults.string(forKey: "provider"), "local")
            XCTAssertEqual(defaults.string(forKey: "localModel"), "gemma-4-e2b")
            XCTAssertEqual(defaults.string(forKey: "dictationModel"), "qwen3ASR")
            XCTAssertEqual(defaults.string(forKey: "harnessModel.openai"), "synthetic-model")
        }
    }

    func testLocalModelRecommendationUsesMemoryPolicy() {
        for memory in [8, 12, 16] {
            let needed = LocalModel.gemma4E2B.downloadBytes + LocalModelFiles.storageMargin
            XCTAssertEqual(FirstRunRecommendations.localFallback(languages: ["ru", "en"],
                physicalMemory: UInt64(memory) << 30, availableStorage: needed), .gemma4E2B)
        }
        for memory in [18, 24, 32, 64] {
            let needed = LocalModel.translateGemma12B.downloadBytes + LocalModelFiles.storageMargin
            XCTAssertEqual(FirstRunRecommendations.localFallback(languages: ["ru", "en"],
                physicalMemory: UInt64(memory) << 30, availableStorage: needed), .translateGemma12B)
        }
    }

    func testFreshProfilesChooseSpeechAndTranslationModelsTogether() {
        for memory: UInt64 in [8, 16, 24, 32] {
            withSuite { defaults in
                FirstRunRecommendations.apply(in: defaults, suggestions: ["ru", "en"],
                                              physicalMemory: memory << 30)
                XCTAssertEqual(defaults.string(forKey: "localModel"),
                               (memory <= 16 ? LocalModel.gemma4E2B : .translateGemma12B).rawValue)
                XCTAssertEqual(defaults.string(forKey: "dictationModel"),
                               (memory <= 16 ? DictationModel.turbo : .qwen3ASR).rawValue)
                FirstRunRecommendations.apply(in: defaults, suggestions: ["de", "en"],
                                              physicalMemory: (memory <= 16 ? 32 : 8) << 30)
                XCTAssertEqual(defaults.string(forKey: "dictationModel"),
                               (memory <= 16 ? DictationModel.turbo : .qwen3ASR).rawValue)
            }
        }
    }

    func testLocalOfferRequiresMeasuredLanguagesMemoryAndSelectedModelStorage() {
        for memory: UInt64 in [8, 16, 24, 32] {
            let model: LocalModel = memory <= 16 ? .gemma4E2B : .translateGemma12B
            let needed = model.downloadBytes + LocalModelFiles.storageMargin
            XCTAssertNil(FirstRunRecommendations.localFallback(languages: ["en"],
                physicalMemory: memory << 30, availableStorage: needed, installed: true))
            for languages in [["ja"], ["ru", "fr"], []] {
                XCTAssertNil(FirstRunRecommendations.localFallback(languages: languages,
                    physicalMemory: memory << 30, availableStorage: needed))
            }
            for available in [nil, needed - 1] {
                XCTAssertNil(FirstRunRecommendations.localFallback(languages: ["en"],
                    physicalMemory: memory << 30, availableStorage: available))
            }
        }
        XCTAssertNil(FirstRunRecommendations.localFallback(languages: ["en"],
            physicalMemory: 4 << 30, availableStorage: Int64.max))
    }

    func testWorkingEngineWaitsForChecksAndKeepsWorkingCurrentChoice() {
        var health = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, EngineHealth.notInstalled) })
        health[.grok] = .working
        health[.openai] = .checking
        XCTAssertNil(FirstRunRecommendations.workingEngine(current: .anthropic, health: health))
        health[.openai] = .working
        XCTAssertEqual(FirstRunRecommendations.workingEngine(current: .anthropic, health: health), .openai)
        XCTAssertEqual(FirstRunRecommendations.workingEngine(current: .grok, health: health), .grok)
        health[.grok] = .notSignedIn
        health[.openai] = .limitReached("Synthetic limit")
        XCTAssertNil(FirstRunRecommendations.workingEngine(current: .anthropic, health: health))
    }

    func testExplicitAndUpgradedProviderChoicesBlockRecommendations() {
        withSuite { defaults in
            XCTAssertTrue(Settings.canRecommendProvider(in: defaults))
            defaults.set("grok", forKey: "provider")
            XCTAssertFalse(Settings.canRecommendProvider(in: defaults))
            Settings.storeRecommendedProvider(.openai, in: defaults)
            XCTAssertTrue(Settings.canRecommendProvider(in: defaults))
            defaults.set(true, forKey: "didCompleteFirstRun")
            XCTAssertFalse(Settings.canRecommendProvider(in: defaults))
        }
    }
}

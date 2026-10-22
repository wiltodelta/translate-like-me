import CoreML
import Foundation
@preconcurrency import MLX
@preconcurrency import WhisperKit
import XCTest
@testable import TranslateLikeMe

final class DictationLanguagePreferenceTests: XCTestCase {
    func testSpokenLanguagesDeduplicateRegionsAndScriptsWithoutMergingCantonese() {
        let preference = DictationLanguagePreference(identifiers: ["pt-BR", "pt-PT", "zh-Hans", "zh-Hant", "yue"])
        XCTAssertEqual(preference.codes, ["pt", "zh", "yue"])
        XCTAssertEqual(preference.resolvedNames(supported: ["Portuguese", "Chinese", "Cantonese"]),
                       ["Portuguese", "Chinese", "Cantonese"])
    }

    @MainActor
    func testConfiguredPairsAreReadAgainAndIncompletePairsAreIgnored() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        let pairs = [LanguagePair(first: "ru", second: "en", shortcut: nil),
                     LanguagePair(first: "pt-BR", second: "pt-PT", shortcut: nil),
                     LanguagePair(first: "de", second: "", shortcut: nil)]
        var domain = saved
        domain["languagePairs"] = try JSONEncoder().encode(pairs)
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        XCTAssertEqual(Set(DictationLanguagePreference.configuredIdentifiers), ["ru", "en", "pt-BR", "pt-PT"])
        domain["languagePairs"] = try JSONEncoder().encode([LanguagePair]())
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        XCTAssertTrue(DictationLanguagePreference.configuredIdentifiers.isEmpty)
    }

    func testEveryWhisperLanguageCodeRoundTripsThroughItsNativeInventory() {
        for code in Constants.languageCodes {
            let preference = DictationLanguagePreference(identifiers: [code])
            XCTAssertEqual(preference.resolvedCodes(supported: Constants.languageCodes), [code], code)
        }
    }

    func testLanguageIdentifiersResolveToWhisperVocabularyWithoutMergingNynorsk() {
        let preference = DictationLanguagePreference(identifiers: ["fil-PH", "jv-ID", "nb-NO", "nn-NO", "iw-IL"])
        XCTAssertEqual(preference.resolvedCodes(supported: Constants.languageCodes), ["tl", "jw", "no", "nn", "he"])
        XCTAssertTrue(DictationLanguagePreference(identifiers: ["nb"]).resolvedCodes(supported: ["nn"]).isEmpty)
    }

    func testLegacyTagalogIdentifierResolvesToQwenFilipinoName() {
        let preference = DictationLanguagePreference(identifiers: ["tl", "en"])
        XCTAssertEqual(preference.resolvedNames(supported: ["Filipino", "English"]), ["Filipino", "English"])
    }

    func testNoPairsAndUnsupportedLanguagesPreserveUnrestrictedDetection() {
        XCTAssertTrue(DictationLanguagePreference(identifiers: []).resolvedCodes(supported: ["en", "ru"]).isEmpty)
        let preference = DictationLanguagePreference(identifiers: ["ru", "uk"])
        XCTAssertTrue(preference.resolvedCodes(supported: ["ru", "en"]).isEmpty)
        XCTAssertTrue(preference.resolvedNames(supported: ["Russian", "English"]).isEmpty)
        let malformed = DictationLanguagePreference(identifiers: ["en", ""])
        XCTAssertTrue(malformed.resolvedCodes(supported: ["en"]).isEmpty)
        XCTAssertTrue(malformed.resolvedNames(supported: ["English"]).isEmpty)
        XCTAssertEqual(preference.resolvedCodes(supported: ["ru", "uk", "en"]), ["ru", "uk"])
    }

    func testLanguagePrefixBiasEndsBeforeTextAndDoesNotAssumeSingleTokenNames() {
        let prefix = DictationLanguagePrefix(start: [1], preferred: [[1, 2], [1, 3, 4]])
        XCTAssertTrue(prefix.nextTokens(after: []).isEmpty)
        XCTAssertEqual(prefix.nextTokens(after: [1]), [2, 3])
        XCTAssertEqual(prefix.nextTokens(after: [1, 3]), [4])
        XCTAssertTrue(prefix.nextTokens(after: [1, 2]).isEmpty)
        XCTAssertTrue(prefix.nextTokens(after: [1, 3, 4]).isEmpty)
        XCTAssertTrue(prefix.nextTokens(after: [1, 9]).isEmpty)
        XCTAssertTrue(prefix.nextTokens(after: [1, 2, 3]).isEmpty)
    }

    func testWhisperPreferenceChangesCloseLanguageChoiceButAllowsStrongOutsideLanguage() async throws {
        let original: [Float] = [0, -0.5, -0.7, -20]
        let baseline = try await sample(original, preferred: [])
        XCTAssertEqual(baseline.tokens.last, 0)
        let biased = try await sample(original, preferred: [1, 2])
        XCTAssertEqual(biased.tokens.last, 1)
        let outside = try await sample([5, 0, -1, -20], preferred: [1, 2])
        XCTAssertEqual(outside.tokens.last, 0)
        let switched = try await sample([0, -0.8, -0.2, -20], preferred: [1, 2])
        XCTAssertEqual(switched.tokens.last, 2)
    }

    func testQwenModifiesVocabularyAxisAndStopsBiasingAfterLanguagePrefix() throws {
        do {
            try DictationQwenTestSupport.configure()
        } catch let error as CocoaError where error.code == .fileNoSuchFile &&
            ProcessInfo.processInfo.environment["TLM_QWEN_METALLIB"] == nil {
            throw XCTSkip("Build the dev app or set TLM_QWEN_METALLIB to run native MLX sampling")
        }
        Device.withDefaultDevice(.cpu) {
            let prefix = DictationLanguagePrefix(start: [9], preferred: [[9, 1], [9, 2]])
            // The real decoder returns batch x sequence x vocabulary, not a vocabulary vector.
            let logits = MLXArray([Float(0), -0.5, -0.7, -20]).reshaped([1, 1, 4])
            XCTAssertEqual(select(logits, [], prefix), 0)
            XCTAssertEqual(select(logits, [9], prefix), 1)
            XCTAssertEqual(select(logits, [9, 1], prefix), 0)
            let strong = MLXArray([Float(5), 0, -1, -20]).reshaped([1, 1, 4])
            XCTAssertEqual(select(strong, [9], prefix), 0)
        }
        // Decoding runs ahead from the reach on, so no preference may apply there.
        let prefix = DictationLanguagePrefix(start: [9], preferred: [[9, 1], [9, 2, 5]])
        XCTAssertEqual(prefix.reach, 3)
        XCTAssertEqual(prefix.nextTokens(after: [9, 2]), [5])
        for generated in [[9, 2, 5], [9, 1, 4], [9, 2, 5, 7]] {
            XCTAssertTrue(prefix.nextTokens(after: generated).isEmpty)
        }
    }

    private func select(_ logits: MLXArray, _ generated: [Int], _ prefix: DictationLanguagePrefix) -> Int {
        DictationQwen.nextToken(logits: logits, generated: generated, prefix: prefix).item(Int.self)
    }

    private func sample(_ values: [Float], preferred: Set<Int>) async throws -> SamplingResult {
        let logits = try MLMultiArray(shape: [1, 1, NSNumber(value: values.count)], dataType: .float16)
        for (index, value) in values.enumerated() { logits[index] = NSNumber(value: value) }
        let base = GreedyTokenSampler(temperature: 0, eotToken: 3, decodingOptions: DecodingOptions())
        let sampler = DictationWhisperLanguageSampler(base: base, preferredTokens: preferred)
        let result = await sampler.update(tokens: [], logits: logits, logProbs: [])
        for token in preferred {
            XCTAssertEqual(logits[token].floatValue, values[token] + DictationLanguagePreference.logWeight,
                           accuracy: 0.01, "The real sampler must receive modified logits")
        }
        return result
    }
}

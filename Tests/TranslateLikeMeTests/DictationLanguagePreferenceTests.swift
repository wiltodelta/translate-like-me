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
    func testConfiguredPairsIncludeIncompleteRowsAndEmptyPairsFallBackToSystemSuggestions() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        let pairs = [LanguagePair(first: "ru", second: "en", shortcut: nil),
                     LanguagePair(first: "pt-BR", second: "pt-PT", shortcut: nil),
                     LanguagePair(first: "de", second: "", shortcut: nil)]
        var domain = saved
        domain["languagePairs"] = try JSONEncoder().encode(pairs)
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        XCTAssertEqual(Set(DictationLanguagePreference.configuredIdentifiers), ["ru", "en", "pt-BR", "pt-PT", "de"])
        XCTAssertEqual(DictationLanguagePreference.identifiers(
            in: [LanguagePair(first: "uk", second: "", shortcut: nil)],
            fallbackSuggestions: ["en", "fr"]
        ), ["uk"])
        XCTAssertEqual(DictationLanguagePreference.identifiers(
            in: [],
            fallbackSuggestions: ["en", "ru"]
        ), ["en", "ru"])
        domain["languagePairs"] = try JSONEncoder().encode([LanguagePair]())
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        XCTAssertEqual(DictationLanguagePreference.configuredIdentifiers,
                       Languages.systemSuggestions.filter { !$0.isEmpty })
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

    func testMixedPairsResolveSupportedSubsetWhileUnresolvedAndAllUnsupportedStayUnrestricted() {
        XCTAssertTrue(DictationLanguagePreference(identifiers: []).resolvedCodes(supported: ["en", "ru"]).isEmpty)
        let mixed = DictationLanguagePreference(identifiers: ["ru", "uk"])
        XCTAssertEqual(mixed.resolvedCodes(supported: ["ru", "en"]), ["ru"])
        XCTAssertEqual(mixed.resolvedNames(supported: ["Russian", "English"]), ["Russian"])
        XCTAssertEqual(mixed.resolvedCodes(supported: ["ru", "uk", "en"]), ["ru", "uk"])
        let unsupportedOnly = DictationLanguagePreference(identifiers: ["uk"])
        XCTAssertTrue(unsupportedOnly.resolvedCodes(supported: ["ru", "en"]).isEmpty)
        XCTAssertTrue(unsupportedOnly.resolvedNames(supported: ["Russian", "English"]).isEmpty)
        let malformed = DictationLanguagePreference(identifiers: ["en", ""])
        XCTAssertTrue(malformed.resolvedCodes(supported: ["en"]).isEmpty)
        XCTAssertTrue(malformed.resolvedNames(supported: ["English"]).isEmpty)
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
        let closeOutside = try await sample([2.0, 0, -1, -20], preferred: [1, 2])
        XCTAssertEqual(closeOutside.tokens.last, 0)
        let switched = try await sample([0, -0.8, -0.2, -20], preferred: [1, 2])
        XCTAssertEqual(switched.tokens.last, 2)
    }

    func testQwenModifiesVocabularyAxisAndStopsBiasingAfterLanguagePrefix() throws {
        try configureQwenOrSkip()
        Device.withDefaultDevice(.cpu) {
            let prefix = DictationLanguagePrefix(start: [9], preferred: [[9, 1], [9, 2]])
            // The real decoder returns batch x sequence x vocabulary, not a vocabulary vector.
            let logits = MLXArray([Float(0), -0.5, -0.7, -20]).reshaped([1, 1, 4])
            XCTAssertEqual(select(logits, [], prefix), 0)
            XCTAssertEqual(select(logits, [9], prefix), 1)
            XCTAssertEqual(select(logits, [9, 1], prefix), 0)
            let strong = MLXArray([Float(5), 0, -1, -20]).reshaped([1, 1, 4])
            XCTAssertEqual(select(strong, [9], prefix), 0)
            let closeOutside = MLXArray([Float(2.0), 0, -1, -20]).reshaped([1, 1, 4])
            XCTAssertEqual(select(closeOutside, [9], prefix), 0)
        }
        // Decoding runs ahead from the reach on, so no preference may apply there.
        let prefix = DictationLanguagePrefix(start: [9], preferred: [[9, 1], [9, 2, 5]])
        XCTAssertEqual(prefix.reach, 3)
        XCTAssertEqual(prefix.nextTokens(after: [9, 2]), [5])
        for generated in [[9, 2, 5], [9, 1, 4], [9, 2, 5, 7]] {
            XCTAssertTrue(prefix.nextTokens(after: generated).isEmpty)
        }
    }

    func testShortWhisperWeightSuppressesModerateOutsideEscapeWhilePreservingStrongOutsideSpeech() async throws {
        let moderateOutside: [Float] = [2.4, 0, -0.5, -20]
        let normalResult = try await sample(moderateOutside, preferred: [1, 2])
        XCTAssertEqual(normalResult.tokens.last, 0)
        let shortResult = try await sample(moderateOutside, preferred: [1, 2],
                                           logWeight: DictationLanguagePreference.shortWhisperLogWeight)
        XCTAssertEqual(shortResult.tokens.last, 1)
        let strongOutside = try await sample([3.3, 0, -0.5, -20], preferred: [1, 2],
                                             logWeight: DictationLanguagePreference.shortWhisperLogWeight)
        XCTAssertEqual(strongOutside.tokens.last, 0)
    }

    func testShortQwenWeightSuppressesOutsideLanguageAndPreservesNoSpeechMargin() throws {
        try configureQwenOrSkip()
        let shortPrefix = DictationLanguagePrefix(
            start: [9], preferred: [[9, 1], [9, 2]], noSpeech: [9, 3],
            logWeight: DictationLanguagePreference.shortQwenLogWeight
        )
        XCTAssertEqual(shortPrefix.noSpeechBoost, log(Float(16)), accuracy: 1e-5)
        Device.withDefaultDevice(.cpu) {
            let moderateOutside = MLXArray([Float(3.0), 0, -0.5, -5.0]).reshaped([1, 1, 4])
            XCTAssertEqual(select(moderateOutside, [9], shortPrefix), 1)
            let strongOutside = MLXArray([Float(5.0), 0, -0.5, -5.0]).reshaped([1, 1, 4])
            XCTAssertEqual(select(strongOutside, [9], shortPrefix), 0)
            // Keep `language None` margin relative to preferred languages at exact `log(4)`.
            let noiseWins = MLXArray([Float(0), 0, -0.5, 1.6]).reshaped([1, 1, 4])
            XCTAssertEqual(select(noiseWins, [9], shortPrefix), 3)
            let speechWins = MLXArray([Float(0), 0, -0.5, 1.2]).reshaped([1, 1, 4])
            XCTAssertEqual(select(speechWins, [9], shortPrefix), 1)
            let emptyPreferred = DictationLanguagePrefix(
                start: [9], preferred: [], noSpeech: [9, 3],
                logWeight: DictationLanguagePreference.shortQwenLogWeight
            )
            XCTAssertEqual(emptyPreferred.noSpeechBoost, 0)
            XCTAssertEqual(emptyPreferred.reach, 0)
            XCTAssertEqual(select(MLXArray([Float(0), -0.5, -0.7, -0.2]).reshaped([1, 1, 4]), [9], emptyPreferred), 0)
        }
        let multiTokenNoSpeech = DictationLanguagePrefix(
            start: [9], preferred: [[9, 1]], noSpeech: [9, 3, 4],
            logWeight: DictationLanguagePreference.shortQwenLogWeight
        )
        XCTAssertEqual(multiTokenNoSpeech.reach, 3)
        XCTAssertEqual(multiTokenNoSpeech.noSpeechToken(after: [9, 3]), 4)
        XCTAssertNil(multiTokenNoSpeech.noSpeechToken(after: [9, 3, 4]))
    }

    func testSpeechDetectorMeasuresActiveSamplesAndCollarBounds() async throws {
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.wiltodelta.translatelikeme.dev/Dictation")
        let engine = DictationEngine(directory: cache)
        let detectorRoot: URL
        do {
            detectorRoot = try await engine.prepareSpeechDetector(in: cache, download: false) { _ in }
        } catch {
            throw XCTSkip("Prepare local dev dictation models to run offline Silero span checks")
        }
        let detector = try DictationSpeechDetector(
            directory: detectorRoot.appendingPathComponent(DictationEngine.detectorModel)
        )
        XCTAssertNil(try detector.detectSpeech(in: []))
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tlm-vad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let shortClip = try synthesize("Да.", voice: "Milena", into: scratch.appendingPathComponent("da.aiff"))
        let paddedShort = Array(repeating: Float(0), count: 24_000) + shortClip
            + Array(repeating: Float(0), count: 24_000)
        let shortSpan = try XCTUnwrap(detector.detectSpeech(in: paddedShort))
        XCTAssertGreaterThan(shortSpan.activeSamples, 0)
        XCTAssertLessThanOrEqual(shortSpan.activeSamples, DictationLanguagePreference.shortSpeechSamples)
        XCTAssertGreaterThanOrEqual(shortSpan.bounds.lowerBound, 12_000)
        XCTAssertLessThanOrEqual(shortSpan.bounds.upperBound, paddedShort.count - 12_000)
        XCTAssertEqual(shortSpan.bounds, try detector.speechBounds(in: paddedShort))

        let firstWord = try synthesize("Сессия.", voice: "Milena", into: scratch.appendingPathComponent("first.aiff"))
        let nextURL = scratch.appendingPathComponent("next.aiff")
        let secondWord = try synthesize("Продолжай.", voice: "Milena", into: nextURL)
        let paused = firstWord + Array(repeating: Float(0), count: 12_800) + secondWord
        let pausedSpan = try XCTUnwrap(detector.detectSpeech(in: paused))
        XCTAssertGreaterThan(pausedSpan.activeSamples, DictationLanguagePreference.shortSpeechSamples)
        XCTAssertGreaterThan(pausedSpan.bounds.count, pausedSpan.activeSamples + 12_000)
    }

    private func synthesize(_ text: String, voice: String, into url: URL) throws -> [Float] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-r", "180", "-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("Voice \(voice) is not installed on this Mac")
        }
        return try DictationAudioLoader.load(url)
    }

    private func configureQwenOrSkip() throws {
        do {
            try DictationQwenTestSupport.configure()
        } catch let error as CocoaError where error.code == .fileNoSuchFile &&
            ProcessInfo.processInfo.environment["TLM_QWEN_METALLIB"] == nil {
            throw XCTSkip("Build the dev app or set TLM_QWEN_METALLIB to run native MLX sampling")
        }
    }

    private func select(_ logits: MLXArray, _ generated: [Int], _ prefix: DictationLanguagePrefix) -> Int {
        DictationQwen.nextToken(logits: logits, generated: generated, prefix: prefix).item(Int.self)
    }

    private func sample(_ values: [Float], preferred: Set<Int>,
                        logWeight: Float = DictationLanguagePreference.logWeight) async throws -> SamplingResult {
        let logits = try MLMultiArray(shape: [1, 1, NSNumber(value: values.count)], dataType: .float16)
        for (index, value) in values.enumerated() { logits[index] = NSNumber(value: value) }
        let base = GreedyTokenSampler(temperature: 0, eotToken: 3, decodingOptions: DecodingOptions())
        let sampler = DictationWhisperLanguageSampler(base: base, preferredTokens: preferred, logWeight: logWeight)
        let result = await sampler.update(tokens: [], logits: logits, logProbs: [])
        for token in preferred {
            XCTAssertEqual(logits[token].floatValue, values[token] + logWeight,
                           accuracy: 0.01, "The real sampler must receive modified logits")
        }
        return result
    }
}

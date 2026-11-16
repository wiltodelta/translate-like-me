import Foundation

// A bounded preference, not a language lock or a calibrated confidence threshold.
// Resolve the supported subset against the active engine's inventory so mixed pairs
// still prioritize supported languages while malformed identifiers stay unrestricted.
struct DictationLanguagePreference: Sendable {
    static let logWeight = log(Float(4))
    static let shortWhisperLogWeight = log(Float(20))
    static let shortQwenLogWeight = log(Float(64))
    // Up to four 256 ms Silero speech windows (~1.15 s at 16 kHz) cover 1-3 syllable
    // utterances while leaving multi-word phrases in outside languages at normal weight.
    static let shortSpeechSamples = 18_432

    @MainActor
    static var configuredIdentifiers: [String] {
        identifiers(in: Settings.languagePairs, fallbackSuggestions: Languages.systemSuggestions)
    }

    static func resolveConfiguredIdentifiers() async -> [String] {
        let configured = identifiers(in: Settings.languagePairs)
        if !configured.isEmpty { return configured }
        return await MainActor.run { Languages.systemSuggestions.filter { !$0.isEmpty } }
    }

    static func identifiers(in pairs: [LanguagePair],
                            fallbackSuggestions: @autoclosure () -> [String] = []) -> [String] {
        let configured = pairs.flatMap { [$0.first, $0.second] }.filter { !$0.isEmpty }
        return configured.isEmpty ? fallbackSuggestions().filter { !$0.isEmpty } : configured
    }
    let codes: Set<String>
    private let hasUnresolvedIdentifiers: Bool

    init(identifiers: [String]) {
        let parsed = identifiers.compactMap(Self.languageCode)
        codes = Set(parsed)
        hasUnresolvedIdentifiers = parsed.count != identifiers.count
    }

    func resolvedCodes(supported: Set<String>) -> Set<String> {
        guard !hasUnresolvedIdentifiers else { return [] }
        let inventory = supported.sorted()
        let native = codes.compactMap { code in
            inventory.first { Self.languageCode($0) == code }
        }
        return Set(native)
    }

    // Foundation's registry handles aliases such as tl/fil, jw/jv, iw/he and no/nb.
    // Match canonical identities, but return the actual IDs in the model's tokenizer.
    private static func languageCode(_ identifier: String) -> String? {
        let canonical = Locale.canonicalLanguageIdentifier(from: identifier.replacingOccurrences(of: "_", with: "-"))
        return Locale.Language(identifier: canonical).languageCode?.identifier
    }

    func resolvedNames(supported: [String]) -> Set<String> {
        guard !hasUnresolvedIdentifiers else { return [] }
        let english = Locale(identifier: "en")
        let names = codes.compactMap { english.localizedString(forLanguageCode: $0) }
        let inventory = Dictionary(supported.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let resolved = names.compactMap { inventory[$0.lowercased()] }
        return Set(resolved)
    }
}

// Prefixes come from the active tokenizer, including multi-token language names.
// Stop biasing as soon as the language is complete or generation leaves its prefix.
struct DictationLanguagePrefix: Sendable {
    let start: [Int]
    let preferred: [[Int]]
    let noSpeech: [Int]
    let logWeight: Float

    init(start: [Int], preferred: [[Int]], noSpeech: [Int] = [],
         logWeight: Float = DictationLanguagePreference.logWeight) {
        self.start = start
        self.preferred = preferred
        self.noSpeech = noSpeech
        self.logWeight = logWeight
    }

    // Keep Qwen's `language None` margin relative to preferred languages unchanged at
    // `log(4)` when short-utterance preference raises spoken candidates over 3rd languages.
    var noSpeechBoost: Float {
        guard !preferred.isEmpty, !noSpeech.isEmpty,
              logWeight > DictationLanguagePreference.logWeight else { return 0 }
        return logWeight - DictationLanguagePreference.logWeight
    }

    // From this many generated tokens on, no preference can apply.
    var reach: Int {
        let preferredReach = preferred.map(\.count).max() ?? 0
        return noSpeechBoost > 0 ? max(preferredReach, noSpeech.count) : preferredReach
    }

    func nextTokens(after generated: [Int]) -> Set<Int> {
        guard generated.starts(with: start),
              !preferred.contains(generated) else { return [] }
        return Set(preferred.compactMap { path in
            guard path.starts(with: generated), path.count > generated.count else { return nil }
            return path[generated.count]
        })
    }

    func noSpeechToken(after generated: [Int]) -> Int? {
        guard noSpeechBoost > 0, generated.starts(with: start),
              noSpeech.starts(with: generated), noSpeech.count > generated.count else { return nil }
        return noSpeech[generated.count]
    }
}

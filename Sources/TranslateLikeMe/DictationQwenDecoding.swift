import Foundation

// Qwen's greedy token loop stays in the calling task, so cancellation drains
// inference before the controller permits another session or runtime unload.
enum DictationQwenDecoding {
    enum Failure: Error, Equatable { case tokenLimit(Int), repetition(Int) }
    enum HeaderOutcome: Equatable {
        case language(String)
        case noSpeech
        case fallback
    }

    struct ShortCandidate: Equatable, Sendable {
        let language: String
        let text: String
        let confidence: Float
    }

    static let rescoreMarginLimit: Float = 8.0
    static let confidentWordLogProb: Float = -0.12
    static let minimumChallengerLogProb: Float = -0.90
    static let challengerSwitchMargin: Float = 0.05
    static let contextScriptTieBonus: Float = 0.04

    static func decode(endTokens: Set<Int>, maximumTokens: Int = 1024,
                       next: (Int?) throws -> Int) throws -> [Int] {
        var tokens: [Int] = []
        for _ in 0..<maximumTokens {
            try Task.checkCancellation()
            let token = try next(tokens.last)
            if endTokens.contains(token) { return tokens }
            tokens.append(token)
            // Match the SDK's greedy repetition backstop, but report an error
            // instead of delivering a silently truncated transcript.
            if tokens.count >= 24, Set(tokens.suffix(24)).count <= 3 { throw Failure.repetition(tokens.count) }
        }
        throw Failure.tokenLimit(tokens.count)
    }

    static func transcript(_ source: String) -> String {
        if let header = splitHeader(source) { return header.body }
        return source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func headerOutcome(_ source: String, supported: [String]) -> HeaderOutcome {
        guard let header = splitHeader(source), !header.language.isEmpty else { return .fallback }
        if header.language.caseInsensitiveCompare("None") == .orderedSame { return .noSpeech }
        if let match = supported.first(where: { $0.caseInsensitiveCompare(header.language) == .orderedSame }) {
            return .language(match)
        }
        return .fallback
    }

    private static func splitHeader(_ source: String) -> (language: String, body: String)? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("language "), let marker = text.range(of: "<asr_text>") else { return nil }
        let start = text.index(text.startIndex, offsetBy: "language ".count)
        let language = text[start..<marker.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (language, body)
    }

    static func needsChallengerRescore(primary: ShortCandidate) -> Bool {
        !hasAlphanumeric(primary.text) || primary.confidence < confidentWordLogProb
    }

    static func selectShortCandidate(primary: ShortCandidate, challenger: ShortCandidate,
                                     context: String = "") -> ShortCandidate {
        guard hasAlphanumeric(challenger.text),
              challenger.confidence >= minimumChallengerLogProb else { return primary }
        guard hasAlphanumeric(primary.text) else { return challenger }
        guard (challenger.confidence + contextScriptTieBonus) - primary.confidence > challengerSwitchMargin,
              !arePhoneticCognates(primary.text, challenger.text) else { return primary }
        let bonus = contextScriptAdjustment(primaryText: primary.text, challengerText: challenger.text,
                                            context: context)
        let gain = (challenger.confidence + bonus) - primary.confidence
        return gain > challengerSwitchMargin ? challenger : primary
    }

    // Sum uppercase and lowercase word-initial BPE paths (e.g. Cyrillic `Д`+`а` vs `да`)
    // so arbitrary utterance-initial capitalization does not penalize short-word confidence.
    static func caseVariantStartTokens(for text: String, language: String = "", greedyFirstToken: Int,
                                       encode: (String) -> [Int]) -> Set<Int> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return [greedyFirstToken] }
        let rest = String(trimmed.dropFirst())
        let useTurkic = language.caseInsensitiveCompare("Turkish") == .orderedSame
            || first == "İ" || first == "ı"
        let locale = useTurkic ? DictationVocabulary.turkicLocale : Locale(identifier: "en_US_POSIX")
        let variants = Set([String(first).lowercased(with: locale) + rest,
                            String(first).uppercased(with: locale) + rest,
                            trimmed.lowercased(with: locale)])
        var ids: Set<Int> = [greedyFirstToken]
        for variant in variants {
            if let token = encode(variant).first { ids.insert(token) }
        }
        return ids
    }

    static func arePhoneticCognates(_ lhs: String, _ rhs: String) -> Bool {
        let leftKey = phoneticSkeleton(lhs)
        let rightKey = phoneticSkeleton(rhs)
        guard !leftKey.isEmpty, !rightKey.isEmpty else { return false }
        if leftKey == rightKey { return true }
        guard min(leftKey.count, rightKey.count) >= 3,
              abs(leftKey.count - rightKey.count) <= 1 else { return false }
        return VocabularyPhonetics.editDistance(leftKey, rightKey, limit: 1) != nil
    }

    private static func phoneticSkeleton(_ source: String) -> String {
        let latin = VocabularyPhonetics.asciiLatinLowercased(source)
        var mapped: [Character] = []
        for ch in latin where ch >= "a" && ch <= "z" {
            if ch == "c" || ch == "q" {
                mapped.append("k")
            } else if ch == "w" {
                mapped.append("v")
            } else {
                mapped.append(ch)
            }
        }
        let normalized = String(mapped)
            .replacingOccurrences(of: "sh", with: "s")
            .replacingOccurrences(of: "kh", with: "h")
            .replacingOccurrences(of: "ph", with: "f")
        var collapsed: [Character] = []
        for ch in normalized where collapsed.last != ch { collapsed.append(ch) }
        return String(collapsed)
    }

    static func hasAlphanumeric(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .alphanumerics) != nil
    }

    private enum ScriptFamily: Equatable {
        case latin, cyrillic, greek, arabic, hebrew, han, kana, hangul, devanagari, thai
    }

    private static func contextScriptAdjustment(primaryText: String, challengerText: String,
                                                context: String) -> Float {
        guard !context.isEmpty,
              let primaryScript = dominantScript(in: primaryText, minimumLetters: 1),
              let challengerScript = dominantScript(in: challengerText, minimumLetters: 1),
              primaryScript != challengerScript,
              let editorBody = DictationContext.editorBody(from: context),
              let editorScript = dominantScript(in: editorBody, minimumLetters: 3) else { return 0 }
        if editorScript == challengerScript { return contextScriptTieBonus }
        if editorScript == primaryScript { return -contextScriptTieBonus }
        return 0
    }

    private static func dominantScript(in text: String, minimumLetters: Int) -> ScriptFamily? {
        var counts: [ScriptFamily: Int] = [:]
        var total = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            guard let family = scriptFamily(of: scalar.value) else { continue }
            counts[family, default: 0] += 1
            total += 1
        }
        guard total >= minimumLetters,
              let best = counts.max(by: { $0.value < $1.value }),
              best.value * 3 > total * 2 else { return nil }
        return best.key
    }

    private static let scriptRanges: [(ClosedRange<UInt32>, ScriptFamily)] = [
        (0x0041...0x024F, .latin), (0x1E00...0x1EFF, .latin), (0x2C60...0x2C7F, .latin),
        (0xA720...0xA7FF, .latin), (0xAB30...0xAB6F, .latin),
        (0x0400...0x052F, .cyrillic), (0x2DE0...0x2DFF, .cyrillic), (0xA640...0xA69F, .cyrillic),
        (0x0370...0x03FF, .greek), (0x1F00...0x1FFF, .greek),
        (0x0590...0x05FF, .hebrew),
        (0x0600...0x06FF, .arabic), (0x0750...0x077F, .arabic), (0x08A0...0x08FF, .arabic),
        (0xFB50...0xFDFF, .arabic), (0xFE70...0xFEFF, .arabic),
        (0x0900...0x097F, .devanagari),
        (0x0E00...0x0E7F, .thai),
        (0x3040...0x30FF, .kana), (0x31F0...0x31FF, .kana), (0xFF66...0xFF9F, .kana),
        (0x1100...0x11FF, .hangul), (0x3130...0x318F, .hangul), (0xAC00...0xD7AF, .hangul),
        (0x3400...0x4DBF, .han), (0x4E00...0x9FFF, .han), (0xF900...0xFAFF, .han), (0x20000...0x323AF, .han)
    ]

    private static func scriptFamily(of value: UInt32) -> ScriptFamily? {
        scriptRanges.first { $0.0.contains(value) }?.1
    }
}

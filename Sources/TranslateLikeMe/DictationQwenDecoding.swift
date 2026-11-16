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
    static func caseVariantStartTokens(for text: String, greedyFirstToken: Int,
                                       encode: (String) -> [Int]) -> Set<Int> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return [greedyFirstToken] }
        let rest = String(trimmed.dropFirst())
        let variants = Set([String(first).lowercased() + rest,
                            String(first).uppercased() + rest,
                            trimmed.lowercased()])
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
        return withinSingleEdit(Array(leftKey), Array(rightKey))
    }

    private static func phoneticSkeleton(_ source: String) -> String {
        let latin = source.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? source
        var mapped: [Character] = []
        for ch in latin.lowercased() where ch >= "a" && ch <= "z" {
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

    private static func withinSingleEdit(_ lhs: [Character], _ rhs: [Character]) -> Bool {
        var costs = Array(0...rhs.count)
        for (row, leftChar) in lhs.enumerated() {
            var previous = costs[0]
            costs[0] = row + 1
            for (col, rightChar) in rhs.enumerated() {
                let saved = costs[col + 1]
                let step = leftChar == rightChar ? 0 : 1
                costs[col + 1] = min(costs[col + 1] + 1, costs[col] + 1, previous + step)
                previous = saved
            }
        }
        return costs[rhs.count] <= 1
    }

    static func hasAlphanumeric(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .alphanumerics) != nil
    }

    private enum ScriptFamily: Equatable {
        case latin, cyrillic, greek, arabic, hebrew, han, kana, hangul, devanagari
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

    private static func scriptFamily(of value: UInt32) -> ScriptFamily? {
        switch value {
        case 0x0041...0x024F, 0x1E00...0x1EFF: .latin
        case 0x0400...0x052F: .cyrillic
        case 0x0370...0x03FF: .greek
        case 0x0600...0x06FF: .arabic
        case 0x0590...0x05FF: .hebrew
        case 0x0900...0x097F: .devanagari
        case 0x3040...0x30FF: .kana
        case 0xAC00...0xD7AF: .hangul
        case 0x4E00...0x9FFF, 0x3400...0x4DBF: .han
        default: nil
        }
    }
}

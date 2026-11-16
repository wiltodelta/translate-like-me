import Foundation

enum VocabularyScript: Equatable, Sendable {
    case latin, cyrillic, greek, arabic, hebrew, devanagari, katakana, hangul, other

    var isSyllabicOrAbjad: Bool {
        switch self {
        case .katakana, .hangul, .arabic, .hebrew, .devanagari: true
        default: false
        }
    }
}

struct VocabularyFuzzyTerm: Sendable, Equatable {
    let written: String
    let collapsedKey: String
    let phoneticKey: String
    let phoneticStem: String
    let eastAsianConsonants: String
    let script: VocabularyScript
    let wordCount: Int
    let startsWithSingleLetterWord: Bool
    let endsWithSingleLetterWord: Bool
    let hasStructuredSpelling: Bool

    init?(term: String) {
        let collapsed = VocabularyPhonetics.collapsedKey(term)
        guard collapsed.count >= 4 else { return nil }
        let script = VocabularyPhonetics.dominantScript(in: term)
        guard script != .other else { return nil }
        let words = term.split { !$0.isLetter && !$0.isNumber }
        let phonetic = words.map {
            VocabularyPhonetics.wordPhonetic(String($0), script: script, foldEastAsian: false)
        }.joined()
        guard phonetic.count >= 4 else { return nil }
        let eastAsian = words.map {
            VocabularyPhonetics.wordPhonetic(String($0), script: script, foldEastAsian: true)
        }.joined()
        written = term
        collapsedKey = collapsed
        phoneticKey = phonetic
        phoneticStem = VocabularyPhonetics.stem(of: phonetic)
        eastAsianConsonants = VocabularyPhonetics.consonants(eastAsian)
        self.script = script
        wordCount = max(1, words.count)
        startsWithSingleLetterWord = words.first.map { $0.count == 1 && $0.first?.isLetter == true } ?? false
        endsWithSingleLetterWord = words.last.map { $0.count == 1 && $0.first?.isLetter == true } ?? false
        hasStructuredSpelling = VocabularyPhonetics.hasStructuredSpelling(term)
    }
}

enum DictationVocabularyFuzzy {
    fileprivate static let joinerCharacters: Set<Character> = [" ", "\t", "-", "–", "—", "‑", "_", "・", "·"]
    private static let inflectionChars: Set<Character> = ["a", "e", "i", "o", "u", "j", "m", "v", "h"]
    private static let hangulParticles = [
        "에서", "으로", "을", "를", "이", "가", "은", "는", "에", "로", "와", "과", "도", "의", "만"
    ]

    fileprivate struct WordToken {
        let range: Range<String.Index>
        let text: Substring
        let script: VocabularyScript
        let isSentenceStart: Bool
        let isSingleLetter: Bool
        let collapsed: String
        let phonetic: String
        let eastAsianPhonetic: String
    }

    private struct SpanMatch {
        let replacement: String
        let end: Int
        let cost: Int
    }

    private struct SpanKeys {
        let collapsed: String
        let phonetic: String
        let eastAsian: String
    }

    private struct SpanFeatures {
        let rawText: String
        let tokenCount: Int
        let hasJoinerPunctuation: Bool
        let startsWithSingleLetter: Bool
        let endsWithSingleLetter: Bool
        let script: VocabularyScript
        let startsUppercase: Bool
        let isAllUppercase: Bool
        let isSentenceStart: Bool
        let collapsed: String
        let phonetic: String
        let eastAsianConsonants: String
    }

    static func apply(terms: [VocabularyFuzzyTerm], to text: String,
                      startsMidSentence: Bool = false) -> String {
        guard !terms.isEmpty, !text.isEmpty else { return text }
        let tokens = VocabularyTokenizer.tokenize(text, startsMidSentence: startsMidSentence)
        guard !tokens.isEmpty else { return text }
        let maxWindow = min(4, max(3, (terms.map(\.wordCount).max() ?? 1) + 1))
        var output = ""
        output.reserveCapacity(text.count)
        var cursor = text.startIndex
        var index = 0
        while index < tokens.count {
            let tokenStart = tokens[index].range.lowerBound
            if cursor < tokenStart { output.append(contentsOf: text[cursor..<tokenStart]) }
            if let matched = bestMatch(at: index, tokens: tokens, in: text,
                                       terms: terms, maxWindow: maxWindow) {
                output.append(matched.replacement)
                cursor = tokens[matched.end].range.upperBound
                index = matched.end + 1
            } else {
                let end = tokens[index].range.upperBound
                output.append(contentsOf: text[tokenStart..<end])
                cursor = end
                index += 1
            }
        }
        if cursor < text.endIndex { output.append(contentsOf: text[cursor...]) }
        return output
    }

    private static func bestMatch(at start: Int, tokens: [WordToken], in text: String,
                                  terms: [VocabularyFuzzyTerm], maxWindow: Int) -> SpanMatch? {
        var limit = start
        while limit + 1 < tokens.count, limit - start + 1 < maxWindow {
            let gap = text[tokens[limit].range.upperBound..<tokens[limit + 1].range.lowerBound]
            guard !gap.isEmpty || tokens[limit].script == tokens[limit + 1].script,
                  gap.allSatisfy(joinerCharacters.contains) else { break }
            limit += 1
        }
        var best: SpanMatch?
        for end in stride(from: limit, through: start, by: -1) {
            guard let candidate = matchWindow(start: start, end: end, tokens: tokens, in: text, terms: terms) else {
                continue
            }
            if candidate.cost == 0 { return candidate }
            if best == nil || candidate.cost < best!.cost { best = candidate }
        }
        return best
    }

    private static func matchWindow(start: Int, end: Int, tokens: [WordToken], in text: String,
                                    terms: [VocabularyFuzzyTerm]) -> SpanMatch? {
        let base = buildFeatures(start: start, end: end, tokens: tokens, in: text)
        for term in terms {
            if let cost = matchCost(span: base, term: term) {
                return SpanMatch(replacement: term.written, end: end, cost: cost)
            }
        }
        guard tokens[end].script == .hangul,
              let stripped = stripHangulParticle(lastToken: tokens[end].text) else { return nil }
        let stemmed = buildStemmedHangulFeatures(start: start, end: end, stem: stripped.stem,
                                                 tokens: tokens, in: text)
        for term in terms where term.script != .hangul {
            if let cost = matchCost(span: stemmed, term: term) {
                return SpanMatch(replacement: term.written + stripped.particle, end: end, cost: cost)
            }
        }
        return nil
    }

    private static func buildFeatures(start: Int, end: Int, tokens: [WordToken], in text: String) -> SpanFeatures {
        let slice = String(text[tokens[start].range.lowerBound..<tokens[end].range.upperBound])
        let keys: SpanKeys
        if start == end {
            let single = tokens[start]
            keys = SpanKeys(collapsed: single.collapsed, phonetic: single.phonetic,
                            eastAsian: VocabularyPhonetics.consonants(single.eastAsianPhonetic))
        } else {
            let window = tokens[start...end]
            keys = SpanKeys(
                collapsed: window.map(\.collapsed).joined(),
                phonetic: window.map(\.phonetic).joined(),
                eastAsian: VocabularyPhonetics.consonants(window.map(\.eastAsianPhonetic).joined())
            )
        }
        return makeFeatures(raw: slice, span: start...end, tokens: tokens, in: text, keys: keys)
    }

    private static func buildStemmedHangulFeatures(start: Int, end: Int, stem: String,
                                                   tokens: [WordToken], in text: String) -> SpanFeatures {
        let prefix = tokens[start..<end]
        let stemPhonetic = VocabularyPhonetics.wordPhonetic(stem, script: .hangul, foldEastAsian: false)
        let stemEastAsian = VocabularyPhonetics.wordPhonetic(stem, script: .hangul, foldEastAsian: true)
        let keys = SpanKeys(
            collapsed: (prefix.map(\.collapsed) + [VocabularyPhonetics.collapsedKey(stem)]).joined(),
            phonetic: (prefix.map(\.phonetic) + [stemPhonetic]).joined(),
            eastAsian: VocabularyPhonetics.consonants((prefix.map(\.eastAsianPhonetic) + [stemEastAsian]).joined())
        )
        let raw = String(text[tokens[start].range.lowerBound..<tokens[end].range.lowerBound]) + stem
        return makeFeatures(raw: raw, span: start...end, tokens: tokens, in: text, keys: keys)
    }

    private static func makeFeatures(raw: String, span: ClosedRange<Int>, tokens: [WordToken],
                                     in text: String, keys: SpanKeys) -> SpanFeatures {
        let start = span.lowerBound
        let end = span.upperBound
        var hasJoiner = false
        for idx in start..<end {
            let gap = text[tokens[idx].range.upperBound..<tokens[idx + 1].range.lowerBound]
            if gap.contains(where: { !$0.isWhitespace }) { hasJoiner = true; break }
        }
        return SpanFeatures(
            rawText: raw, tokenCount: end - start + 1, hasJoinerPunctuation: hasJoiner,
            startsWithSingleLetter: tokens[start].isSingleLetter,
            endsWithSingleLetter: tokens[end].isSingleLetter,
            script: tokens[start].script, startsUppercase: raw.first?.isUppercase == true,
            isAllUppercase: isAllUppercase(raw), isSentenceStart: tokens[start].isSentenceStart,
            collapsed: keys.collapsed, phonetic: keys.phonetic, eastAsianConsonants: keys.eastAsian
        )
    }

    private static func isAllUppercase(_ text: String) -> Bool {
        var letterCount = 0
        for ch in text where ch.isLetter {
            guard ch.isUppercase else { return false }
            letterCount += 1
        }
        return letterCount >= 2
    }

    private static func matchCost(span: SpanFeatures, term: VocabularyFuzzyTerm) -> Int? {
        if span.tokenCount >= 2 {
            if span.startsWithSingleLetter && !term.startsWithSingleLetterWord { return nil }
            if span.endsWithSingleLetter && !term.endsWithSingleLetterWord { return nil }
        }
        if span.rawText == term.written || matchesCollapsed(span: span, term: term) { return 0 }
        if span.script == term.script {
            return sameScriptPhoneticCost(span: span, term: term)
        }
        return crossScriptCost(span: span, term: term)
    }

    private static func matchesCollapsed(span: SpanFeatures, term: VocabularyFuzzyTerm) -> Bool {
        guard span.collapsed == term.collapsedKey else { return false }
        if span.tokenCount >= 2 || span.hasJoinerPunctuation { return term.collapsedKey.count >= 5 }
        return term.hasStructuredSpelling || span.isAllUppercase || term.collapsedKey.count >= 8
            || (span.startsUppercase && !span.isSentenceStart)
    }

    private static func sameScriptPhoneticCost(span: SpanFeatures, term: VocabularyFuzzyTerm) -> Int? {
        guard !span.script.isSyllabicOrAbjad,
              let first = span.phonetic.first, first == term.phoneticKey.first,
              abs(span.phonetic.count - term.phoneticKey.count) <= 1 else { return nil }
        if term.phoneticKey.count >= 8 {
            return VocabularyPhonetics.editDistance(span.phonetic, term.phoneticKey, limit: 1)
        }
        if term.wordCount >= 2 && term.phoneticKey.count >= 6 {
            return span.phonetic == term.phoneticKey ? 0 : nil
        }
        guard term.phoneticKey.count >= 5, span.tokenCount == 1,
              span.startsUppercase, !span.isSentenceStart else { return nil }
        return VocabularyPhonetics.editDistance(span.phonetic, term.phoneticKey, limit: 1)
    }

    private static func crossScriptCost(span: SpanFeatures, term: VocabularyFuzzyTerm) -> Int? {
        guard span.script != .other, term.phoneticKey.count >= 5 else { return nil }
        if span.script.isSyllabicOrAbjad || term.script.isSyllabicOrAbjad {
            guard term.eastAsianConsonants.count >= 4,
                  let first = span.eastAsianConsonants.first,
                  first == term.eastAsianConsonants.first else { return nil }
            let limit = term.eastAsianConsonants.count >= 6 ? 1 : 0
            return VocabularyPhonetics.editDistance(span.eastAsianConsonants, term.eastAsianConsonants, limit: limit)
        }
        guard let first = span.phonetic.first, first == term.phoneticKey.first else { return nil }
        let limit = term.phoneticKey.count >= 8 ? 2 : 0
        if abs(span.phonetic.count - term.phoneticKey.count) <= 1,
           let distance = VocabularyPhonetics.editDistance(span.phonetic, term.phoneticKey, limit: limit) {
            return distance
        }
        guard span.tokenCount == 1, term.phoneticStem.count >= 4,
              span.phonetic.hasPrefix(term.phoneticStem) else { return nil }
        let suffix = span.phonetic.dropFirst(term.phoneticStem.count)
        return (1...3).contains(suffix.count) && suffix.allSatisfy(inflectionChars.contains) ? 1 : nil
    }

    private static func stripHangulParticle(lastToken: Substring) -> (stem: String, particle: String)? {
        for particle in hangulParticles where lastToken.hasSuffix(particle) {
            let remaining = lastToken.dropLast(particle.count)
            guard !remaining.isEmpty else { continue }
            return (String(remaining), particle)
        }
        return nil
    }
}

private enum VocabularyTokenizer {
    static func tokenize(_ text: String, startsMidSentence: Bool) -> [DictationVocabularyFuzzy.WordToken] {
        var tokens: [DictationVocabularyFuzzy.WordToken] = []
        var index = text.startIndex
        var atSentenceStart = !startsMidSentence
        while index < text.endIndex {
            let ch = text[index]
            if VocabularyPhonetics.isKatakanaWordChar(ch) {
                let start = index
                while index < text.endIndex, VocabularyPhonetics.isKatakanaWordChar(text[index]) {
                    index = text.index(after: index)
                }
                tokens.append(makeToken(range: start..<index, in: text, script: .katakana,
                                        isSentenceStart: atSentenceStart))
                atSentenceStart = false
            } else if DictationVocabulary.requiresWordBoundary(ch) {
                let start = index
                while index < text.endIndex, DictationVocabulary.requiresWordBoundary(text[index]) {
                    index = text.index(after: index)
                }
                let raw = String(text[start..<index])
                tokens.append(makeToken(range: start..<index, in: text,
                                        script: VocabularyPhonetics.dominantScript(in: raw),
                                        isSentenceStart: atSentenceStart))
                atSentenceStart = false
            } else {
                if ch.isNewline || DictationInsertion.isSentenceEnding(ch) {
                    atSentenceStart = true
                } else if !ch.isWhitespace && !DictationVocabularyFuzzy.joinerCharacters.contains(ch)
                            && DictationTextSpacing.isScriptWithoutWordSpaces(ch) {
                    atSentenceStart = false
                }
                index = text.index(after: index)
            }
        }
        return tokens
    }

    private static func makeToken(range: Range<String.Index>, in text: String, script: VocabularyScript,
                                  isSentenceStart: Bool) -> DictationVocabularyFuzzy.WordToken {
        let slice = text[range]
        let word = String(slice)
        let singleLetter = slice.count == 1 && slice.first?.isLetter == true
        let phonetic = VocabularyPhonetics.wordPhonetic(word, script: script, foldEastAsian: false)
        let eastAsian = VocabularyPhonetics.wordPhonetic(word, script: script, foldEastAsian: true)
        return DictationVocabularyFuzzy.WordToken(
            range: range, text: slice, script: script, isSentenceStart: isSentenceStart,
            isSingleLetter: singleLetter,
            collapsed: VocabularyPhonetics.collapsedKey(word),
            phonetic: phonetic, eastAsianPhonetic: eastAsian
        )
    }
}

enum VocabularyPhonetics {
    private static let latinASCIITransform = StringTransform("Any-Latin; Latin-ASCII; Lower")
    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
    private static let katakanaLabials: [(String, String)] = [
        ("ウィ", "vi"), ("ウェ", "ve"), ("ウォ", "vo"), ("ヴァ", "va"), ("ヴィ", "vi"), ("ヴ", "v")
    ]
    private static let phoneticClusters: [(String, String)] = [
        ("tch", "9"), ("ch", "9"), ("sh", "s"), ("kh", "h"), ("ph", "f"), ("gh", "g"),
        ("wh", "v"), ("qu", "kv"), ("ck", "k"), ("ce", "se"), ("ci", "si"), ("cy", "si"),
        ("au", "o"), ("aw", "o"), ("ou", "o"), ("ow", "o"),
        ("ee", "i"), ("ea", "i"), ("ie", "i"), ("ei", "i"), ("ey", "i"), ("ej", "i"), ("yi", "i"),
        ("oo", "u"), ("oj", "oi")
    ]
    private static let scriptRanges: [(ClosedRange<UInt32>, VocabularyScript)] = [
        (0x0041...0x024F, .latin), (0x1E00...0x1EFF, .latin), (0x2C60...0x2C7F, .latin),
        (0xA720...0xA7FF, .latin), (0xAB30...0xAB6F, .latin),
        (0x0400...0x052F, .cyrillic), (0x2DE0...0x2DFF, .cyrillic), (0xA640...0xA69F, .cyrillic),
        (0x0370...0x03FF, .greek), (0x1F00...0x1FFF, .greek),
        (0x0590...0x05FF, .hebrew),
        (0x0600...0x06FF, .arabic), (0x0750...0x077F, .arabic), (0x08A0...0x08FF, .arabic),
        (0xFB50...0xFDFF, .arabic), (0xFE70...0xFEFF, .arabic),
        (0x0900...0x097F, .devanagari),
        (0x30A1...0x30FA, .katakana), (0x30FC...0x30FE, .katakana), (0xFF66...0xFF9F, .katakana),
        (0x1100...0x11FF, .hangul), (0x3130...0x318F, .hangul), (0xAC00...0xD7AF, .hangul)
    ]

    static func collapsedKey(_ text: String) -> String {
        String(DictationVocabulary.caseKey(text).filter(DictationVocabulary.isWordCharacter))
    }

    static func asciiLatinLowercased(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
        return text.applyingTransform(latinASCIITransform, reverse: false) ?? text.lowercased()
    }

    static func wordPhonetic(_ raw: String, script: VocabularyScript, foldEastAsian: Bool) -> String {
        var prepared = raw
        if foldEastAsian && script == .katakana {
            for (kana, romaji) in katakanaLabials {
                prepared = prepared.replacingOccurrences(of: kana, with: romaji)
            }
        }
        let latin = asciiLatinLowercased(prepared)
        var clean = String(latin.filter { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") })
        for (from, to) in phoneticClusters { clean = clean.replacingOccurrences(of: from, with: to) }
        var mapped: [Character] = []
        for ch in clean {
            let norm = mapPhoneticChar(ch, foldEastAsian: foldEastAsian)
            if mapped.last != norm { mapped.append(norm) }
        }
        if script == .latin, mapped.count >= 4, mapped.last == "e", !vowels.contains(mapped[mapped.count - 2]) {
            mapped.removeLast()
        }
        return String(mapped)
    }

    private static func mapPhoneticChar(_ ch: Character, foldEastAsian: Bool) -> Character {
        switch ch {
        case "9": foldEastAsian ? "t" : "c"
        case "c", "q": "k"
        case "w": "v"
        case "y": "i"
        case "z": "s"
        case "r" where foldEastAsian: "l"
        case "b" where foldEastAsian: "v"
        default: ch
        }
    }

    static func consonants(_ phonetic: String) -> String {
        var out: [Character] = []
        for ch in phonetic where !vowels.contains(ch) {
            if out.last != ch { out.append(ch) }
        }
        return String(out)
    }

    static func stem(of phonetic: String) -> String {
        guard phonetic.count >= 5, let last = phonetic.last, vowels.contains(last) else { return phonetic }
        return String(phonetic.dropLast())
    }

    static func hasStructuredSpelling(_ term: String) -> Bool {
        if term.contains(where: { $0.isNumber || $0 == "-" || $0 == "_" }) { return true }
        return term.dropFirst().contains(where: \.isUppercase)
    }

    static func isKatakanaWordChar(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            (0x30A1...0x30FA).contains(scalar.value)
                || (0x30FC...0x30FE).contains(scalar.value)
                || (0xFF66...0xFF9F).contains(scalar.value)
        }
    }

    static func dominantScript(in text: String) -> VocabularyScript {
        var counts: [VocabularyScript: Int] = [:]
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if let hit = scriptRanges.first(where: { $0.0.contains(scalar.value) })?.1 {
                counts[hit, default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key ?? .other
    }

    static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int? {
        if lhs == rhs { return 0 }
        guard limit > 0, abs(lhs.count - rhs.count) <= limit else { return nil }
        let left = Array(lhs)
        let right = Array(rhs)
        var costs = Array(0...right.count)
        for (row, leftChar) in left.enumerated() {
            var previous = costs[0]
            costs[0] = row + 1
            var rowMin = costs[0]
            for (col, rightChar) in right.enumerated() {
                let saved = costs[col + 1]
                let step = leftChar == rightChar ? 0 : 1
                let updated = min(costs[col + 1] + 1, costs[col] + 1, previous + step)
                costs[col + 1] = updated
                rowMin = min(rowMin, updated)
                previous = saved
            }
            if rowMin > limit { return nil }
        }
        return costs[right.count] <= limit ? costs[right.count] : nil
    }
}

import Foundation
import os
@preconcurrency import WhisperKit

// User-configured terms and explicit spoken -> written aliases. Terms condition
// both Qwen's contextual prompt and Whisper's promptTokens; aliases run in one
// left-to-right longest-match pass so rules never cascade into each other.
struct DictationVocabulary: Sendable, Equatable {
    struct Replacement: Sendable, Equatable {
        let spoken: String
        let written: String
        fileprivate let requiresLeadingBoundary: Bool
        fileprivate let requiresTrailingBoundary: Bool
        fileprivate let hasTurkicDot: Bool

        init(spoken: String, written: String) {
            self.spoken = spoken
            self.written = written
            requiresLeadingBoundary = spoken.first.map(DictationVocabulary.requiresWordBoundary) ?? false
            requiresTrailingBoundary = spoken.last.map(DictationVocabulary.requiresWordBoundary) ?? false
            hasTurkicDot = DictationVocabulary.containsTurkicDot(spoken)
        }
    }

    static let empty = DictationVocabulary("")
    static let maxTerms = 64
    static let maxTermLength = 80
    static let maxPromptCharacters = 200
    static let maxWhisperTokens = 64
    static let turkicLocale = Locale(identifier: "tr")
    private static let termSeparators: Set<Character> = [",", "，", "、", "،", ";", "；", "؛"]
    private static let cache = OSAllocatedUnfairLock<(raw: String, parsed: DictationVocabulary)>(
        initialState: ("", .empty)
    )

    let terms: [String]
    let replacements: [Replacement]
    let fuzzyTerms: [VocabularyFuzzyTerm]
    let summary: String

    static func cached(for raw: String) -> DictationVocabulary {
        if raw.isEmpty { return .empty }
        if let existing = cache.withLock({ $0.raw == raw ? $0.parsed : nil }) { return existing }
        let parsed = DictationVocabulary(raw)
        cache.withLock { $0 = (raw, parsed) }
        return parsed
    }

    init(_ raw: String) {
        var parsedTerms: [String] = []
        var seenTerms = Set<String>()
        var parsedReplacements: [Replacement] = []
        var seenSpoken = Set<String>()
        var summaryEntries: [String] = []

        func addTerm(_ candidate: String) -> String? {
            let clean = DictationContext.sanitized(candidate)
            guard !clean.isEmpty, clean.count <= Self.maxTermLength else { return nil }
            let key = Self.caseKey(clean)
            guard seenTerms.insert(key).inserted, parsedTerms.count < Self.maxTerms else { return nil }
            parsedTerms.append(clean)
            return clean
        }

        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let pair = Self.parseReplacement(line) {
                let spokenKey = Self.caseKey(pair.spoken)
                if seenSpoken.insert(spokenKey).inserted {
                    parsedReplacements.append(pair)
                    summaryEntries.append("\(pair.spoken) → \(pair.written)")
                }
                _ = addTerm(pair.written)
            } else {
                for fragment in Self.splitTerms(line) {
                    if let clean = addTerm(fragment) { summaryEntries.append(clean) }
                }
            }
        }

        terms = parsedTerms
        fuzzyTerms = Self.sortedLongestFirst(parsedTerms.compactMap(VocabularyFuzzyTerm.init(term:))) {
            $0.collapsedKey.count
        }
        replacements = Self.sortedLongestFirst(parsedReplacements) { $0.spoken.count }
        summary = summaryEntries.joined(separator: ", ")
    }

    private static func sortedLongestFirst<Element>(_ items: [Element], by length: (Element) -> Int) -> [Element] {
        items.enumerated()
            .sorted { lhs, rhs in
                let leftLength = length(lhs.element)
                let rightLength = length(rhs.element)
                return leftLength != rightLength ? leftLength > rightLength : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    var isEmpty: Bool { terms.isEmpty && replacements.isEmpty }

    var glossaryPrompt: String {
        var selected: [String] = []
        var length = 0
        for term in terms {
            let addition = selected.isEmpty ? term.count : term.count + 2
            guard length + addition <= Self.maxPromptCharacters else { break }
            selected.append(term)
            length += addition
        }
        return selected.joined(separator: ", ")
    }

    func whisperPromptTokens(using tokenizer: (any WhisperTokenizer)?) -> [Int]? {
        let glossary = glossaryPrompt
        guard !glossary.isEmpty, let tokenizer else { return nil }
        let limit = tokenizer.specialTokens.specialTokenBegin
        let encoded = tokenizer.encode(text: " " + glossary).filter { $0 < limit }
        let bounded = Array(encoded.prefix(Self.maxWhisperTokens))
        return bounded.isEmpty ? nil : bounded
    }

    private struct Match {
        let written: String
        let upperBound: String.Index
        let nextUTF16Offset: Int
    }

    func applyReplacements(to text: String) -> String {
        guard !isEmpty, !text.isEmpty else { return text }
        guard !replacements.isEmpty else {
            return DictationVocabularyFuzzy.apply(terms: fuzzyTerms, to: text)
        }
        let nsText = text as NSString
        let allRequireLeadingBoundary = replacements.allSatisfy(\.requiresLeadingBoundary)
        var output = ""
        output.reserveCapacity(text.count)
        var unlockedStart = text.startIndex
        var index = text.startIndex
        var utf16Offset = 0
        func flushUnlocked(upTo end: String.Index) {
            guard unlockedStart < end else { return }
            let segment = String(text[unlockedStart..<end])
            if fuzzyTerms.isEmpty {
                output.append(segment)
            } else {
                let midSentence = DictationInsertion.continuesSentence(
                    in: DictationInsertionContext(beforeSlice: output)
                )
                output.append(DictationVocabularyFuzzy.apply(
                    terms: fuzzyTerms, to: segment, startsMidSentence: midSentence
                ))
            }
        }
        while index < text.endIndex {
            let previousWasWord = index > text.startIndex && Self.isWordCharacter(text[text.index(before: index)])
            if !(previousWasWord && allRequireLeadingBoundary),
               let matched = matchAt(index, utf16Offset: utf16Offset, previousWasWord: previousWasWord,
                                     in: text, nsText: nsText) {
                flushUnlocked(upTo: index)
                output.append(matched.written)
                index = matched.upperBound
                unlockedStart = index
                utf16Offset = matched.nextUTF16Offset
            } else {
                utf16Offset += text[index].utf16.count
                index = text.index(after: index)
            }
        }
        if unlockedStart == text.startIndex {
            return fuzzyTerms.isEmpty ? text : DictationVocabularyFuzzy.apply(terms: fuzzyTerms, to: text)
        }
        flushUnlocked(upTo: text.endIndex)
        return output
    }

    private func matchAt(_ index: String.Index, utf16Offset: Int, previousWasWord: Bool,
                         in text: String, nsText: NSString) -> Match? {
        let searchRange = NSRange(location: utf16Offset, length: nsText.length - utf16Offset)
        let current = text[index]
        let currentIsTurkic = current == "İ" || current == "ı"
        for rule in replacements {
            if rule.requiresLeadingBoundary && previousWasWord { continue }
            var found = nsText.range(of: rule.spoken, options: [.anchored, .caseInsensitive], range: searchRange)
            if found.location == NSNotFound, rule.hasTurkicDot || currentIsTurkic {
                found = nsText.range(of: rule.spoken, options: [.anchored, .caseInsensitive],
                                     range: searchRange, locale: Self.turkicLocale)
            }
            guard found.location == utf16Offset, found.length > 0 else { continue }
            let endUTF16 = text.utf16.index(index, offsetBy: found.length)
            guard let upper = endUTF16.samePosition(in: text),
                  upper == text.endIndex || text.rangeOfComposedCharacterSequence(at: upper).lowerBound == upper else {
                continue
            }
            if rule.requiresTrailingBoundary, upper < text.endIndex, Self.isWordCharacter(text[upper]) { continue }
            return Match(written: rule.written, upperBound: upper, nextUTF16Offset: utf16Offset + found.length)
        }
        return nil
    }

    static func requiresWordBoundary(_ character: Character) -> Bool {
        isWordCharacter(character) && !DictationTextSpacing.isScriptWithoutWordSpaces(character)
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    static func containsTurkicDot(_ value: String) -> Bool {
        value.contains("İ") || value.contains("ı")
    }

    static func caseKey(_ value: String) -> String {
        containsTurkicDot(value) ? value.lowercased(with: turkicLocale) : value.lowercased()
    }

    private static func parseReplacement(_ line: String) -> Replacement? {
        for arrow in ["->", "→"] {
            guard let divider = line.range(of: arrow) else { continue }
            let left = DictationContext.sanitized(String(line[..<divider.lowerBound]))
            let right = DictationContext.sanitized(String(line[divider.upperBound...]))
            guard !left.isEmpty, !right.isEmpty,
                  left.count <= maxTermLength, right.count <= maxTermLength else { return nil }
            return Replacement(spoken: left, written: right)
        }
        return nil
    }

    private static func splitTerms(_ line: String) -> [String] {
        line.split(whereSeparator: termSeparators.contains).map(String.init)
    }
}

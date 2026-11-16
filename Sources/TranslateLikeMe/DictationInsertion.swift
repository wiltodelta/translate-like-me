import Foundation
import NaturalLanguage

struct DictationInsertionContext: Sendable, Equatable {
    static let sliceLimit = 24

    var beforeSlice: String?
    var afterSlice: String?
    var hasCompleteLinePrefix: Bool

    var beforeCaret: Character? { beforeSlice?.last }
    var afterCaret: Character? { afterSlice?.first }

    init(beforeSlice: String? = nil, afterSlice: String? = nil, hasCompleteLinePrefix: Bool = true) {
        self.beforeSlice = beforeSlice
        self.afterSlice = afterSlice
        self.hasCompleteLinePrefix = hasCompleteLinePrefix
    }

    init(beforeCaret: Character?) {
        self.beforeSlice = beforeCaret.map(String.init)
        self.afterSlice = nil
        self.hasCompleteLinePrefix = false
    }
}

struct DictationInsertionTarget: Sendable, Equatable {
    let pid: pid_t
    let context: DictationInsertionContext

    var beforeCaret: Character? { context.beforeCaret }

    init(pid: pid_t, context: DictationInsertionContext = DictationInsertionContext()) {
        self.pid = pid
        self.context = context
    }
}

enum DictationInsertion {
    private static let autoPeriods: Set<Character> = [".", "。", "۔", "।", "։"]
    private static let continuationPunctuation: Set<Character> = [
        ",", ";", "،", "؛", "，", "、", "՝", "/", "&"
    ]
    private static let nonSpaceAfterPrefixes: Set<Character> = [
        "(", "[", "{", "<", "\"", "'", "«", "“", "‘", "/", "\\", "-", "–", "—",
        "@", "#", "$", "€", "£", "¥", "₹", "₽", "¿", "¡"
    ]
    private static let nonSpaceBeforeSuffixes: Set<Character> = [
        ")", "]", "}", ">", ",", ";", ":", ".", "!", "?", "…", "/", "\\", "-", "–", "—",
        "，", "、", "।", "۔", "؟", "؛", "：", "。", "！", "？", "）", "】", "」", "』", "»", "”", "’"
    ]
    private static let lowercaseLatinILanguages: Set<String> = [
        "pl", "cs", "sk", "hr", "sl", "bs", "sr", "it", "ro", "ca", "sq", "vi", "tr", "az"
    ]
    private static let nameAwareLanguages: Set<NLLanguage> = [
        .english, .french, .spanish, .italian, .portuguese, .german
    ]
    private static let germanLowercaseClasses: Set<NLTag> = [
        .verb, .adverb, .adjective, .pronoun, .conjunction,
        .preposition, .determiner, .particle, .interjection, .number
    ]

    static func format(_ text: String, context: DictationInsertionContext,
                       vocabulary: DictationVocabulary = .empty,
                       languageIdentifiers: [String] = []) -> String {
        guard !text.isEmpty else { return text }
        let continuing = continuesSentence(in: context)
        var adjusted = continuing
            ? lowercaseLeadingWordIfSafe(text, vocabulary: vocabulary, languageIdentifiers: languageIdentifiers)
            : text
        adjusted = stripAutoPeriodIfMidLine(adjusted, context: context, isContinuation: continuing)
        if let beforeCaret = context.beforeCaret, let first = adjusted.first,
           needsLeadingSpace(after: beforeCaret, before: first) {
            adjusted = " " + adjusted
        }
        if let afterCaret = context.afterCaret, let last = adjusted.last,
           needsTrailingSpace(after: last, before: afterCaret) {
            adjusted += " "
        }
        return adjusted
    }

    static func continuesSentence(in context: DictationInsertionContext) -> Bool {
        guard let (linePrefix, lineStartsHere) = linePrefix(in: context), !linePrefix.isEmpty else { return false }
        let trimmed = trimTrailingWhitespace(linePrefix)
        guard let previous = trimmed.last else { return false }
        if lineStartsHere && isListOrHeadingMarker(trimmed) { return false }
        if hasProperty(previous, where: \.isQuotationMark) || isSentenceEnding(previous) { return false }
        if previous.isLetter || previous.isNumber { return true }
        if continuationPunctuation.contains(previous) || hasProperty(previous, where: \.isDash) { return true }
        return hasProperty(previous) {
            $0.generalCategory == .openPunctuation || $0.generalCategory == .closePunctuation
        }
    }

    static func needsLeadingSpace(after previous: Character, before next: Character) -> Bool {
        guard !previous.isWhitespace, !isAttachedPrefix(previous),
              !DictationTextSpacing.isScriptWithoutWordSpaces(previous),
              !DictationTextSpacing.isScriptWithoutWordSpaces(next) else { return false }
        if next.isLetter || next.isNumber { return true }
        return next == "¿" || next == "¡" || hasProperty(next) {
            $0.generalCategory == .openPunctuation || $0.generalCategory == .initialPunctuation
        }
    }

    static func needsTrailingSpace(after last: Character, before next: Character) -> Bool {
        needsLeadingSpace(after: last, before: next)
    }

    private static func stripAutoPeriodIfMidLine(_ text: String, context: DictationInsertionContext,
                                                 isContinuation: Bool) -> String {
        guard let afterSlice = context.afterSlice, !afterSlice.isEmpty,
              let last = text.last, autoPeriods.contains(last) else { return text }
        let afterOnLine = afterSlice.prefix { !$0.isNewline }
        let trimmedAfter = afterOnLine.drop(while: \.isWhitespace)
        guard let next = trimmedAfter.first else { return text }
        let stem = text.dropLast()
        guard !stem.isEmpty, !stem.contains(where: isSentenceEnding) else { return text }
        let shouldStrip = nonSpaceBeforeSuffixes.contains(next)
            || hasProperty(next, where: { $0.generalCategory == .closePunctuation })
            || isContinuation
            || (hasEmptyLinePrefix(in: context) && next.isLowercase)
        return shouldStrip ? String(stem) : text
    }

    private static func linePrefix(in context: DictationInsertionContext) -> (text: Substring, isComplete: Bool)? {
        guard let beforeSlice = context.beforeSlice else { return nil }
        if let newlineIndex = beforeSlice.lastIndex(where: \.isNewline) {
            return (beforeSlice[beforeSlice.index(after: newlineIndex)...], true)
        }
        return (beforeSlice[...], context.hasCompleteLinePrefix)
    }

    private static func hasEmptyLinePrefix(in context: DictationInsertionContext) -> Bool {
        guard let (prefix, isComplete) = linePrefix(in: context) else { return false }
        return isComplete && prefix.allSatisfy(\.isWhitespace)
    }

    private static func lowercaseLeadingWordIfSafe(_ text: String, vocabulary: DictationVocabulary,
                                                   languageIdentifiers: [String]) -> String {
        guard let first = text.first, first.isLetter, first.isUppercase else { return text }
        let token = text.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "'" || $0 == "’" || $0 == "_" }
        if token.hasPrefix("I'") || token.hasPrefix("I’") { return text }
        let rest = token.dropFirst()
        guard !token.contains(where: \.isNumber), !rest.contains(where: \.isUppercase),
              !matchesCapitalizedVocabulary(in: text, vocabulary: vocabulary) else { return text }
        if first != "İ" && VocabularyPhonetics.dominantScript(in: String(first)) != .latin {
            return String(first).lowercased(with: Locale(identifier: "en_US_POSIX")) + text.dropFirst()
        }
        let configuredCodes = DictationLanguagePreference(identifiers: languageIdentifiers).codes
        let language = resolvedLanguage(for: text, configuredCodes: configuredCodes)
        if shouldPreserveLatinI(token: token, language: language, configuredCodes: configuredCodes) { return text }
        if shouldPreserveByLexicalTag(text: text, language: language) { return text }
        let locale = localeForLowercasing(first: first, language: language, configuredCodes: configuredCodes)
        return String(first).lowercased(with: locale) + text.dropFirst()
    }

    private static func matchesCapitalizedVocabulary(in text: String, vocabulary: DictationVocabulary) -> Bool {
        for term in vocabulary.terms where term.first?.isUppercase == true {
            guard let range = text.range(of: term, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) else {
                continue
            }
            if range.upperBound == text.endIndex || !DictationVocabulary.isWordCharacter(text[range.upperBound]) {
                return true
            }
        }
        return false
    }

    private static func resolvedLanguage(for text: String, configuredCodes: Set<String>) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        if !configuredCodes.isEmpty {
            recognizer.languageHints = Dictionary(
                uniqueKeysWithValues: configuredCodes.map { (NLLanguage(rawValue: $0), 0.15) }
            )
        }
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    private static func shouldPreserveLatinI(token: Substring, language: NLLanguage?,
                                             configuredCodes: Set<String>) -> Bool {
        if token.hasPrefix("I'") || token.hasPrefix("I’") { return true }
        guard token == "I" else { return false }
        if let code = language?.rawValue, lowercaseLatinILanguages.contains(code) { return false }
        if !configuredCodes.isEmpty && !configuredCodes.contains("en")
            && !configuredCodes.isDisjoint(with: lowercaseLatinILanguages) {
            return false
        }
        return true
    }

    private static func shouldPreserveByLexicalTag(text: String, language: NLLanguage?) -> Bool {
        guard let language, nameAwareLanguages.contains(language) else { return false }
        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass])
        tagger.string = text
        tagger.setLanguage(language, range: text.startIndex..<text.endIndex)
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .word, scheme: .nameTypeOrLexicalClass)
        if language == .german {
            guard let tag else { return true }
            return !germanLowercaseClasses.contains(tag)
        }
        return tag == .personalName || tag == .placeName || tag == .organizationName
    }

    private static func localeForLowercasing(first: Character, language: NLLanguage?,
                                             configuredCodes: Set<String>) -> Locale {
        if first == "İ" { return DictationVocabulary.turkicLocale }
        if let code = language?.rawValue {
            if code == "tr" || code == "az" { return DictationVocabulary.turkicLocale }
            return Locale(identifier: code)
        }
        if configuredCodes.contains("tr") || configuredCodes.contains("az") {
            return DictationVocabulary.turkicLocale
        }
        return Locale(identifier: "en_US_POSIX")
    }

    private static func isListOrHeadingMarker(_ line: Substring) -> Bool {
        let stripped = line.drop(while: \.isWhitespace)
        guard !stripped.isEmpty else { return false }
        if stripped.allSatisfy({ $0 == "#" || $0 == ">" }) { return true }
        if stripped.count == 1, let marker = stripped.first,
           ["-", "–", "—", "*", "+", "•"].contains(marker) {
            return true
        }
        if let last = stripped.last, last == ")" || last == ".",
           !stripped.dropLast().isEmpty, stripped.dropLast().allSatisfy(\.isNumber) {
            return true
        }
        return false
    }

    private static func isAttachedPrefix(_ character: Character) -> Bool {
        if nonSpaceAfterPrefixes.contains(character) { return true }
        return hasProperty(character) {
            $0.generalCategory == .openPunctuation || $0.generalCategory == .initialPunctuation
        }
    }

    static func isSentenceEnding(_ character: Character) -> Bool {
        if character == "…" || character == "¿" || character == "¡" || character == "՜" { return true }
        return hasProperty(character, where: \.isSentenceTerminal)
    }

    private static func trimTrailingWhitespace(_ slice: Substring) -> Substring {
        var end = slice.endIndex
        while end > slice.startIndex {
            let previous = slice.index(before: end)
            guard slice[previous].isWhitespace else { break }
            end = previous
        }
        return slice[..<end]
    }

    private static func hasProperty(_ character: Character,
                                    where predicate: (Unicode.Scalar.Properties) -> Bool) -> Bool {
        character.unicodeScalars.contains { predicate($0.properties) }
    }
}

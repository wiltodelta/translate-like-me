import Foundation

// Bounded gain normalization for quiet headset and distant-microphone captures.
// Normal inputs (>= 0.15 peak) and near-zero floors (< 0.003 peak) stay untouched.
enum DictationAudioGain {
    static let minimumPeak: Float = 0.003
    static let activationPeak: Float = 0.15
    static let targetPeak: Float = 0.30
    static let maximumGain: Float = 16.0

    static func normalize(_ samples: [Float], peak measuredPeak: Float? = nil) -> (samples: [Float], gain: Float) {
        let peak = measuredPeak ?? samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak >= minimumPeak, peak < activationPeak else { return (samples, 1) }
        let gain = min(maximumGain, targetPeak / peak)
        return (samples.map { max(-1, min(1, $0 * gain)) }, gain)
    }
}

struct DictationDestinationSnapshot: Sendable, Equatable {
    var appName: String?
    var windowTitle: String?
    var surroundingText: String?
}

// Ephemeral destination metadata for contextual speech decoding. Never logged or persisted.
enum DictationContext {
    static let beforeCaretLimit = 180
    static let afterCaretLimit = 60
    private static let vocabularyPrefix = "Vocabulary: "

    static func live() -> String {
        summary(destination: SelectionTarget.dictationSnapshot())
    }

    static func sanitized(_ text: String) -> String {
        // Remove angle brackets unconditionally so nested or truncated text can
        // never form Qwen chat-template or ASR control tokens (`<|...|>` / `<asr_text>`).
        String(text.filter { $0 != "<" && $0 != ">" })
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func combined(vocabulary: DictationVocabulary = .empty, destination: String, limit: Int = 360) -> String {
        let glossary = vocabulary.glossaryPrompt
        let safeDestination = String(destination.filter { $0 != "<" && $0 != ">" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !glossary.isEmpty else { return capped(safeDestination, limit: limit) }
        let header = vocabularyPrefix + glossary
        guard !safeDestination.isEmpty else { return String(header.prefix(limit)) }
        let remaining = limit - header.count - 1
        guard remaining > 0 else { return String(header.prefix(limit)) }
        return header + "\n" + capped(safeDestination, limit: remaining)
    }

    static func summary(destination: DictationDestinationSnapshot) -> String {
        var sections: [String] = []
        let app = cleaned(destination.appName, limit: 48, keepTail: false)
        let window = cleaned(destination.windowTitle, limit: 100, keepTail: false)
        if !app.isEmpty, !window.isEmpty, window.caseInsensitiveCompare(app) != .orderedSame {
            sections.append("\(app) - \(window)")
        } else if !window.isEmpty {
            sections.append(window)
        } else if !app.isEmpty {
            sections.append(app)
        }
        let surrounding = cleaned(destination.surroundingText, limit: 200, keepTail: true)
        if !surrounding.isEmpty { sections.append(surrounding) }
        return capped(sections.joined(separator: "\n"))
    }

    static func chunkContext(base: String, vocabulary: DictationVocabulary = .empty,
                             previousChunks: [String]) -> String {
        let body: String
        if previousChunks.isEmpty {
            body = base
        } else {
            var recent: [String] = []
            var count = 0
            for chunk in previousChunks.reversed() where !chunk.isEmpty {
                recent.append(chunk)
                count += chunk.count + 1
                if count >= 160 { break }
            }
            let tail = cleaned(DictationTextSpacing.joinChunks(recent.reversed()), limit: 140, keepTail: true)
            if tail.isEmpty || base.hasSuffix(tail) {
                body = base
            } else {
                body = base.isEmpty ? tail : base + "\n" + tail
            }
        }
        return combined(vocabulary: vocabulary, destination: body)
    }

    // `selection` uses UTF-16 code units, matching Accessibility's CFRange contract.
    static func characterBeforeCaret(in value: String, selection: NSRange) -> Character? {
        guard selection.length == 0, selection.location > 0,
              let caret = scalarBoundary(at: selection.location, in: value),
              caret > value.startIndex else { return nil }
        return value[value.index(before: caret)]
    }

    static func surroundingText(in value: String, selection: NSRange) -> String? {
        guard selection.location >= 0, selection.length >= 0 else { return nil }
        let (endOffset, overflow) = selection.location.addingReportingOverflow(selection.length)
        guard !overflow,
              let start = scalarBoundary(at: selection.location, in: value),
              let end = scalarBoundary(at: endOffset, in: value) else { return nil }
        let prefix = String(value[..<start].suffix(beforeCaretLimit))
        let suffix = String(value[end...].prefix(afterCaretLimit))
        let joined = [prefix, suffix].map { cleaned($0, limit: 240, keepTail: true) }.filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private static func scalarBoundary(at utf16Offset: Int, in value: String) -> String.Index? {
        guard utf16Offset >= 0 else { return nil }
        let utf16 = value.utf16
        guard let position = utf16.index(utf16.startIndex, offsetBy: utf16Offset, limitedBy: utf16.endIndex) else {
            return nil
        }
        return String.Index(position, within: value)
    }

    private static func capped(_ text: String, limit: Int = 360) -> String {
        text.count > limit ? String(text.suffix(limit)) : text
    }

    private static func cleaned(_ text: String?, limit: Int, keepTail: Bool) -> String {
        guard let text else { return "" }
        let compact = sanitized(text)
        guard compact.count > limit else { return compact }
        return keepTail ? String(compact.suffix(limit)) : String(compact.prefix(limit))
    }
}

enum DictationTextSpacing {
    private static let attachedPrefixes: Set<Character> = [
        "(", "[", "{", "<", "\"", "'", "«", "“", "‘", "/", "\\", "-", "–", "—", "@", "#", "$"
    ]

    static func joinChunks(_ chunks: [String]) -> String {
        var combined = ""
        for raw in chunks {
            let chunk = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty else { continue }
            if let previous = combined.last, let next = chunk.first,
               !isScriptWithoutWordSpaces(previous) || !isScriptWithoutWordSpaces(next) {
                combined.append(" ")
            }
            combined.append(chunk)
        }
        return combined
    }

    static func formatForInsertion(_ text: String, beforeCaret: Character?) -> String {
        guard let beforeCaret, let first = text.first,
              needsLeadingSpace(after: beforeCaret, before: first) else { return text }
        return " " + text
    }

    static func needsLeadingSpace(after previous: Character, before next: Character) -> Bool {
        guard !previous.isWhitespace, !attachedPrefixes.contains(previous),
              !isScriptWithoutWordSpaces(previous), !isScriptWithoutWordSpaces(next) else { return false }
        return next.isLetter || next.isNumber
    }

    static func isScriptWithoutWordSpaces(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xF900...0xFAFF, 0xFF01...0xFF60, 0x20000...0x2CEAF,
                 0x0E00...0x0E7F: // CJK ideographs/kana/fullwidth punctuation and Thai
                return true
            default:
                return false
            }
        }
    }
}

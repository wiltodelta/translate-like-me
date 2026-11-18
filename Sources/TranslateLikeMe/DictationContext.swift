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

// Ephemeral destination metadata for contextual speech decoding. Never logged or persisted.
enum DictationContext {
    static let beforeCaretLimit = TextCaretSlices.beforeCaretLimit
    static let afterCaretLimit = TextCaretSlices.afterCaretLimit
    private static let vocabularyPrefix = "Vocabulary: "

    static func live() async -> String {
        if AppEdition.current == .appStore {
            return summary(destination: await BridgeClient.shared.fetchDictationSnapshot())
        }
        return summary(destination: SelectionTarget.dictationSnapshot())
    }

    static func sanitized(_ text: String) -> String {
        TextCaretSlices.sanitized(text)
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

    // Line 0 after removing any pinned `Vocabulary:` prefix is the app/window header
    // from `summary(destination:)`; subsequent lines carry actual editor text.
    static func editorBody(from context: String) -> String? {
        guard !context.isEmpty else { return nil }
        let lines = context.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(vocabularyPrefix) }
        guard lines.count >= 2 else { return nil }
        return lines.dropFirst().joined(separator: " ")
    }

    // `selection` uses UTF-16 code units, matching Accessibility's CFRange contract.
    static func characterBeforeCaret(in value: String, selection: NSRange) -> Character? {
        insertionContext(in: value, selection: selection).beforeCaret
    }

    static func insertionContext(in value: String, selection: NSRange,
                                 limit: Int = DictationInsertionContext.sliceLimit) -> DictationInsertionContext {
        TextCaretSlices.insertionContext(in: value, selection: selection, limit: limit)
    }

    static func surroundingText(in value: String, selection: NSRange) -> String? {
        TextCaretSlices.surroundingText(in: value, selection: selection)
    }

    private static func capped(_ text: String, limit: Int = 360) -> String {
        text.count > limit ? String(text.suffix(limit)) : text
    }

    private static func cleaned(_ text: String?, limit: Int, keepTail: Bool) -> String {
        TextCaretSlices.cleaned(text, limit: limit, keepTail: keepTail)
    }
}

enum DictationTextSpacing {
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
        DictationInsertion.format(text, context: DictationInsertionContext(beforeCaret: beforeCaret))
    }

    static func isScriptWithoutWordSpaces(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xF900...0xFAFF, 0xFF01...0xFF60, 0xFF61...0xFF9F,
                 0x20000...0x2CEAF, 0x30000...0x323AF, // CJK ideographs, kana, halfwidth/fullwidth forms
                 0x0E00...0x0EFF, 0x0F00...0x0FFF,     // Thai, Lao, Tibetan
                 0x1000...0x109F, 0x1780...0x17FF, 0x19E0...0x19FF: // Myanmar, Khmer
                return true
            default:
                return false
            }
        }
    }
}

import Carbon
import Foundation

// A language the user can pick for a translation pair. `name` is the English
// name shown in the UI and fed to the model; `code` is the persisted id, a BCP 47
// tag, with a script or region only where the written language differs.
struct Language: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

// A global key combination: a Carbon virtual key code and modifier mask.
struct KeyCombo: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
}

// Two languages translated between, with an optional shortcut of its own. The
// input's language is detected; text in `first` becomes `second`, and text in
// `second` or in any other language becomes `first`.
struct LanguagePair: Codable, Equatable, Identifiable {
    var id = UUID()
    var first: String
    var second: String
    var shortcut: KeyCombo?

    var title: String { "\(Languages.name(for: first)) ↔ \(Languages.name(for: second))" }
}

enum Languages {
    // A curated list of common languages. Order roughly by popularity.
    static let all: [Language] = [
        Language(code: "en", name: "English"),
        Language(code: "ru", name: "Russian"),
        Language(code: "es", name: "Spanish"),
        Language(code: "fr", name: "French"),
        Language(code: "de", name: "German"),
        Language(code: "it", name: "Italian"),
        Language(code: "pt-BR", name: "Portuguese (Brazil)"),
        Language(code: "pt-PT", name: "Portuguese (Portugal)"),
        Language(code: "nl", name: "Dutch"),
        Language(code: "pl", name: "Polish"),
        Language(code: "uk", name: "Ukrainian"),
        Language(code: "tr", name: "Turkish"),
        Language(code: "ar", name: "Arabic"),
        Language(code: "he", name: "Hebrew"),
        Language(code: "hi", name: "Hindi"),
        Language(code: "zh-Hans", name: "Chinese (Simplified)"),
        Language(code: "zh-Hant", name: "Chinese (Traditional)"),
        Language(code: "ja", name: "Japanese"),
        Language(code: "ko", name: "Korean"),
        Language(code: "vi", name: "Vietnamese"),
        Language(code: "th", name: "Thai"),
        Language(code: "id", name: "Indonesian"),
        Language(code: "sv", name: "Swedish"),
        Language(code: "no", name: "Norwegian"),
        Language(code: "da", name: "Danish"),
        Language(code: "fi", name: "Finnish"),
        Language(code: "cs", name: "Czech"),
        Language(code: "el", name: "Greek"),
        Language(code: "ro", name: "Romanian"),
        Language(code: "hu", name: "Hungarian")
    ]

    // Pairs beyond this are not offered: each one is a shortcut to remember.
    static let maxPairs = 3

    // Codes persisted before the list carried scripts and regions.
    private static let legacyCodes = ["zh": "zh-Hans", "pt": "pt-BR"]

    static func normalized(_ code: String) -> String {
        legacyCodes[code] ?? code
    }

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }

    // The listed language for a system language identifier ("ru-US",
    // "zh-Hans-CN", "pt-BR"): the longest listed code it starts with.
    static func code(forPreferred identifier: String) -> String? {
        let parts = identifier.split(separator: "-")
        for count in stride(from: parts.count, through: 1, by: -1) {
            // A bare "zh" or "pt" maps to the listed default variant.
            let candidate = normalized(parts.prefix(count).joined(separator: "-"))
            if let match = all.first(where: { $0.code.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return match.code
            }
        }
        return nil
    }

    // The first pair for a new user: the first system language that is listed,
    // with the next listed system language, else English (or Spanish for an
    // English speaker).
    static func defaultPair(preferred: [String]) -> LanguagePair {
        var seen: [String] = []
        for code in preferred.compactMap(code(forPreferred:)) where !seen.contains(code) { seen.append(code) }
        let first = seen.first ?? "en"
        let second = seen.dropFirst().first ?? (first == "en" ? "es" : "en")
        return LanguagePair(first: first, second: second, shortcut: defaultShortcut)
    }

    // ⌥⌘F, the shortcut the first pair starts with.
    static let defaultShortcut = KeyCombo(keyCode: 3, modifiers: Int(cmdKey | optionKey))

    // A new pair: the first pair's first language with the first listed
    // language it is not already paired with. No shortcut until one is recorded.
    static func newPair(after pairs: [LanguagePair]) -> LanguagePair {
        let first = pairs.first?.first ?? "en"
        let taken = Set(pairs.filter { $0.first == first || $0.second == first }.flatMap { [$0.first, $0.second] })
        let second = all.first { $0.code != first && !taken.contains($0.code) }?.code ?? "en"
        return LanguagePair(first: first, second: second, shortcut: nil)
    }

    // The pair after setting one side to `code`. The two sides stay distinct:
    // picking the language already on the other side swaps them.
    static func setting(_ pair: LanguagePair, first isFirst: Bool, to code: String) -> LanguagePair {
        var pair = pair
        if isFirst {
            if code == pair.second { pair.second = pair.first }
            pair.first = code
        } else {
            if code == pair.first { pair.first = pair.second }
            pair.second = code
        }
        return pair
    }
}

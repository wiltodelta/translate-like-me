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

// Two languages translated between, with an optional shortcut and writing style
// of its own. The input's language is detected; text in `first` becomes
// `second`, and text in `second` or in any other language becomes `first`. Two
// pairs may share languages, say one with the user's style for their own text
// and one without for someone else's.
struct LanguagePair: Codable, Equatable, Identifiable {
    var id = UUID()
    var first: String
    // Empty until chosen, when the Mac suggested no second language.
    var second: String
    var shortcut: KeyCombo?
    // Applied to this pair's translations; blank means a plain translation.
    var style = ""

    var title: String { "\(Languages.name(for: first)) ↔ \(isComplete ? Languages.name(for: second) : "…")" }

    // The second language chosen; a new pair may leave it to the user.
    var isComplete: Bool { !second.isEmpty }

    // The style as applied; empty for a plain translation.
    var trimmedStyle: String { style.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// In an extension, so the memberwise initializer stays synthesized.
extension LanguagePair {
    // Pairs stored before styles moved into them have no style key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        first = try container.decode(String.self, forKey: .first)
        second = try container.decode(String.self, forKey: .second)
        shortcut = try container.decodeIfPresent(KeyCombo.self, forKey: .shortcut)
        style = try container.decodeIfPresent(String.self, forKey: .style) ?? ""
    }
}

enum Languages {
    // Every language macOS has a locale for (307 on macOS 27), named in English
    // and sorted by name. A language written in several scripts is listed once
    // per script (zh-Hans, zh-Hant, sr-Cyrl, sr-Latn), except Aran, a Nastaliq
    // style of the Arabic script rather than a script of its own. Portuguese is
    // listed by region, as the two written standards differ.
    static let all: [Language] = {
        var scripts: [String: Set<String>] = [:]
        for identifier in Locale.availableIdentifiers {
            let language = Locale.Components(identifier: identifier).languageComponents
            guard let code = language.languageCode?.identifier else { continue }
            var found = scripts[code, default: []]
            if let script = language.script?.identifier, script != "Aran" { found.insert(script) }
            scripts[code] = found
        }
        var codes: [String] = []
        for (code, found) in scripts {
            if code == "pt" {
                codes += ["pt-BR", "pt-PT"]
            } else if found.count > 1 {
                codes += found.map { "\(code)-\($0)" }
            } else {
                codes.append(code)
            }
        }
        let english = Locale(identifier: "en")
        return codes
            .map { Language(code: $0, name: english.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    // Keyed by lowercased code, so lookups ignore case ("zh-hant").
    private static let byCode = Dictionary(uniqueKeysWithValues: all.map { ($0.code.lowercased(), $0) })

    // Pairs beyond this are not offered: each one is a shortcut to remember.
    static let maxPairs = 3

    // Codes persisted before the list carried scripts and regions.
    private static let legacyCodes = ["zh": "zh-Hans", "pt": "pt-BR"]

    static func normalized(_ code: String) -> String {
        legacyCodes[code] ?? code
    }

    static func name(for code: String) -> String {
        byCode[code.lowercased()]?.name ?? code
    }

    // The listed language for a system language identifier ("ru-US",
    // "zh-Hans-CN", "pt-BR", "sr"): the longest listed code it starts with, and
    // for a language listed only by script, the script it is written in by
    // default ("sr" is Cyrillic).
    static func code(forPreferred identifier: String) -> String? {
        let tag = identifier.replacingOccurrences(of: "_", with: "-")
        return longestListedPrefix(of: tag)
            ?? longestListedPrefix(of: Locale.Language(identifier: tag).maximalIdentifier)
    }

    private static func longestListedPrefix(of tag: String) -> String? {
        let parts = tag.split(separator: "-")
        for count in stride(from: parts.count, through: 1, by: -1) {
            // A bare "zh" or "pt" maps to the listed default variant.
            let prefix = normalized(parts.prefix(count).joined(separator: "-"))
            if let match = byCode[prefix.lowercased()] { return match.code }
        }
        return nil
    }

    // The languages this Mac says its user reads or writes, most telling
    // first, without repeats: the system languages (Language & Region), then
    // each enabled keyboard layout's own language, then the region's language,
    // then English, which most people translate to and from. Empty strings
    // and unlisted languages are skipped.
    static func suggestions(preferred: [String], keyboards: [String], region: String?) -> [String] {
        let regionLanguage = region.map { Locale.Language(identifier: "und-\($0)").maximalIdentifier }
        var seen: [String] = []
        for identifier in preferred + keyboards + [regionLanguage, "en"].compactMap({ $0 }) {
            guard let code = code(forPreferred: identifier), !seen.contains(code) else { continue }
            seen.append(code)
        }
        return seen
    }

    static var systemSuggestions: [String] {
        suggestions(preferred: Locale.preferredLanguages, keyboards: keyboardLanguages,
                    region: Locale.current.region?.identifier)
    }

    // The primary language of each enabled keyboard layout or input method
    // (U.S. is English, RussianWin Russian), in the order macOS lists them.
    private static var keyboardLanguages: [String] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any]
        guard let sources = TISCreateInputSourceList(filter as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] else { return [] }
        return sources.compactMap { source in
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
            return (Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? [String])?.first
        }
    }

    // ⌥⌘F, the shortcut the first pair starts with.
    static let defaultShortcut = KeyCombo(keyCode: 3, modifiers: Int(cmdKey | optionKey))

    // A new pair: the first pair's first language (for the very first pair,
    // the first suggestion, on ⌥⌘F) with the next suggestion it is not already
    // paired with. When none is left (an English Mac with a U.S. layout in the
    // US knows one language) the second is left unchosen rather than guessed.
    // Later pairs get no shortcut until one is recorded.
    static func newPair(after pairs: [LanguagePair],
                        suggestions: [String] = systemSuggestions) -> LanguagePair {
        let first = pairs.first?.first ?? suggestions.first ?? "en"
        let taken = Set(pairs.filter { $0.first == first || $0.second == first }.flatMap { [$0.first, $0.second] })
        let second = suggestions.first { $0 != first && !taken.contains($0) } ?? ""
        return LanguagePair(first: first, second: second, shortcut: pairs.isEmpty ? defaultShortcut : nil)
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

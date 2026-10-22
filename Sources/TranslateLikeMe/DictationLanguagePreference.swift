import Foundation

// A bounded preference, not a language lock or a calibrated confidence threshold.
// Resolve against the active engine's inventory; never silently drop an unsupported language.
struct DictationLanguagePreference: Sendable {
    static let logWeight = log(Float(4))

    static var configuredIdentifiers: [String] {
        Settings.languagePairs.filter(\.isComplete).flatMap { [$0.first, $0.second] }
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
        return native.count == codes.count ? Set(native) : []
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
        guard names.count == codes.count else { return [] }
        let inventory = Dictionary(supported.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let resolved = names.compactMap { inventory[$0.lowercased()] }
        return resolved.count == codes.count ? Set(resolved) : []
    }
}

// Prefixes come from the active tokenizer, including multi-token language names.
// Stop biasing as soon as the language is complete or generation leaves its prefix.
struct DictationLanguagePrefix: Sendable {
    let start: [Int]
    let preferred: [[Int]]
    // From this many generated tokens on, no preference can apply.
    var reach: Int { preferred.map(\.count).max() ?? 0 }

    func nextTokens(after generated: [Int]) -> Set<Int> {
        guard generated.starts(with: start),
              !preferred.contains(generated) else { return [] }
        return Set(preferred.compactMap { path in
            guard path.starts(with: generated), path.count > generated.count else { return nil }
            return path[generated.count]
        })
    }
}

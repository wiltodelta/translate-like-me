import Foundation

// Resolves the model for API-key mode at runtime, on this machine, instead of
// pinning a version in the app: query the provider's live /models list and pick
// the newest of the tier (Sonnet / GPT fast tier), with a pinned last-resort
// fallback used only when the list is unavailable. Subscription (CLI) mode does
// not pick a model: each CLI runs with the user's own default model and effort
// (HarnessDefaults), or its built-in default.
enum ModelResolver {
    // Last-resort fallbacks if the live model list can't be fetched. Kept only so
    // a network hiccup doesn't break translation outright.
    static let anthropicFallback = "claude-sonnet-5"
    // The current OpenAI fast-tier id (2026-09-22).
    private static let openaiFallback = "gpt-6-luna"

    // OpenAI's fast, cheap tier. It was "gpt-N-mini" until the 2026 rename to
    // "gpt-N-luna" ("Fast and affordable model for easier tasks" in codex's
    // model cache); both are accepted so an older API list still resolves, and
    // luna wins over mini at any version.
    private static func fastTierRank(_ slug: String) -> Int? {
        let id = slug.lowercased()
        guard id.hasPrefix("gpt-") else { return nil }
        if id.contains("luna") { return 1 }
        if id.contains("mini") { return 0 }
        return nil
    }

    private static func newestFastTier(_ slugs: [String]) -> String? {
        let ranked = slugs.compactMap { slug in fastTierRank(slug).map { (slug, $0) } }
        // Tier first, then the highest version embedded in the slug (gpt-5.6-luna -> 5.6).
        return ranked.max { lhs, rhs in
            (lhs.1, versionValue(of: lhs.0)) < (rhs.1, versionValue(of: rhs.0))
        }?.0
    }

    private static func versionValue(of slug: String) -> Double {
        let start = slug.drop { !$0.isNumber }
        let number = start.prefix { $0.isNumber || $0 == "." }
        return Double(number) ?? 0
    }

    private static var cache: [Provider: String] = [:]

    static func clearCache() { cache = [:] }

    // Concrete model id for API-key mode, resolved from the live /models list.
    static func apiModel(provider: Provider, key: String) async -> String {
        if let cached = cache[provider] { return cached }

        let resolved: String
        if let ids = try? await APIClient.listModels(provider: provider, key: key),
           let match = pick(provider: provider, from: ids) {
            resolved = match
        } else {
            resolved = provider == .anthropic ? anthropicFallback : openaiFallback
        }
        cache[provider] = resolved
        return resolved
    }

    // ids are newest-first; return the newest one matching the tier.
    // Internal (not private) so the tier-selection logic can be unit-tested.
    static func pick(provider: Provider, from ids: [String]) -> String? {
        switch provider {
        case .anthropic:
            return ids.first { $0.lowercased().contains("sonnet") }
        case .openai:
            let textModels = ids.filter {
                let id = $0.lowercased()
                return !id.contains("audio") && !id.contains("realtime")
                    && !id.contains("transcribe") && !id.contains("tts")
            }
            return newestFastTier(textModels)
        case .grok:
            // Grok has no API-key mode; its CLI picks its own default model.
            return nil
        }
    }
}

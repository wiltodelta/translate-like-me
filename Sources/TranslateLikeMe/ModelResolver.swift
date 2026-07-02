import Foundation

// Resolves which model to use at runtime, on this machine, instead of pinning a
// version in the app - so all four paths follow model updates automatically:
//   Claude API / OpenAI API : query the provider's live /models list, pick the
//                             newest of the tier (Sonnet / GPT "mini").
//   Claude subscription     : the `sonnet` alias (the CLI resolves it to latest).
//   Codex subscription      : read codex's own on-disk model cache and pick the
//                             newest "mini" (codexModel()).
// Each has a pinned last-resort fallback used only when its source is unavailable.
enum ModelResolver {
    // Tier selectors. Not pinned version ids - these pick the latest match live.
    static let claudeCLIAlias = "sonnet"

    // Last-resort fallbacks if the live model list can't be fetched. Kept only so
    // a network hiccup doesn't break translation outright.
    private static let anthropicFallback = "claude-sonnet-4-6"
    private static let openaiFallback = "gpt-5.4-mini"

    // The newest "mini" model the Codex/ChatGPT account can use, read from codex's
    // own on-disk model cache. Codex maintains and refreshes this file as new
    // models ship, so this follows updates (e.g. gpt-5.4-mini -> gpt-5.5-mini)
    // without a pinned id and without needing an API key. Falls back to a known
    // id if the cache is missing or unreadable.
    static func codexModel() -> String {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? (NSHomeDirectory() + "/.codex")
        let url = URL(fileURLWithPath: home).appendingPathComponent("models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return openaiFallback
        }
        let minis = models
            .compactMap { $0["slug"] as? String }
            .filter { $0.hasPrefix("gpt-") && $0.contains("mini") }
        // Pick the highest version number embedded in the slug (gpt-5.4-mini -> 5.4).
        let best = minis.max { versionValue(of: $0) < versionValue(of: $1) }
        return best ?? openaiFallback
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
    private static func pick(provider: Provider, from ids: [String]) -> String? {
        switch provider {
        case .anthropic:
            return ids.first { $0.lowercased().contains("sonnet") }
        case .openai:
            return ids.first {
                let id = $0.lowercased()
                return id.hasPrefix("gpt-") && id.contains("mini") && !id.contains("audio")
                    && !id.contains("realtime") && !id.contains("transcribe") && !id.contains("tts")
            }
        }
    }
}

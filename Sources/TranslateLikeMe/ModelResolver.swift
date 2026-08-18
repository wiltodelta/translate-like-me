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
    private static let opencodeFallback = "opencode/big-pickle"

    // The newest "mini" model the Codex/ChatGPT account can use, read from codex's
    // own on-disk model cache. Codex maintains and refreshes this file as new
    // models ship, so this follows updates (e.g. gpt-5.4-mini -> gpt-5.5-mini)
    // without a pinned id and without needing an API key. Falls back to a known
    // id if the cache is missing or unreadable.
    static func codexModel() -> String {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? (NSHomeDirectory() + "/.codex")
        guard let json = readJSONCache(home + "/models_cache.json"),
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

    // The OpenCode engine's model, "opencode/<id>". Priority, set by the
    // 2026-08-18 translation benchmark (app's real prompt, ru<->en: register,
    // question-form preservation, idiom handling, latency):
    //   1. deepseek-v4-flash-free - best quality and fastest of the alive set
    //   2. big-pickle - the zen gateway's vendor-rotated tuned default
    //   3. the newest "-free" zen model by release_date
    // The zen tier also rotates availability: models that 500 today may answer
    // tomorrow, so the picker falls through rather than pinning one id. All
    // read live from opencode's own models.dev cache
    // (~/.cache/opencode/models.json), which opencode refreshes. Cached per
    // launch like apiModel: the file only changes when the opencode CLI
    // itself refreshes it.
    static func opencodeModel() -> String {
        if let cached = cache[.opencode] { return cached }
        let picked = readJSONCache(NSHomeDirectory() + "/.cache/opencode/models.json")
            .flatMap { pickZenModel(from: $0) } ?? opencodeFallback
        cache[.opencode] = picked
        return picked
    }

    // Internal (not private) so the zen-picking logic can be unit-tested.
    // The cache shape is [provider: ["models": [id: ["release_date": ISO, ...]]]].
    static func pickZenModel(from cache: [String: Any]) -> String? {
        guard let zen = cache["opencode"] as? [String: Any],
              let models = zen["models"] as? [String: Any] else { return nil }
        if models["deepseek-v4-flash-free"] != nil {
            return "opencode/deepseek-v4-flash-free"
        }
        if models["big-pickle"] != nil { return opencodeFallback }
        // ISO dates sort lexicographically, newest release_date wins.
        let frees = models.compactMap { id, value -> (String, String)? in
            guard let info = value as? [String: Any],
                  let date = info["release_date"] as? String else { return nil }
            return (id, date)
        }.filter { $0.0.hasSuffix("-free") }
        return frees.max { $0.1 < $1.1 }.map { "opencode/" + $0.0 }
    }

    // Shared disk-cache reader for the per-engine model caches.
    private static func readJSONCache(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
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
            return ids.first {
                let id = $0.lowercased()
                return id.hasPrefix("gpt-") && id.contains("mini") && !id.contains("audio")
                    && !id.contains("realtime") && !id.contains("transcribe") && !id.contains("tts")
            }
        case .opencode:
            // OpenCode has no API-key mode; zen models are picked by
            // pickZenModel(from:) from opencode's own on-disk cache instead.
            return nil
        }
    }
}

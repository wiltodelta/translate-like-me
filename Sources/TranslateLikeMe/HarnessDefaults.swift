import Foundation

// The model and effort the user set as defaults in each CLI's own config. The
// app runs claude and codex isolated from that config (`--setting-sources ""`,
// `--ignore-user-config`) to keep MCP servers and instruction files out of a
// translation, so it reads just these two values and passes them back as flags.
// A nil field means "not set": the CLI then uses its own built-in default. A
// model tied to another provider (a settings `env` that reroutes claude, a
// codex `model_provider`) is not passed, because the isolated run cannot see
// that provider; only the effort is. Codex profiles are not followed.
// grok is not isolated from its config.toml, so it applies its defaults itself.
enum HarnessDefaults {
    // The configured defaults for a provider's CLI; grok applies its own, so the
    // app knows none for it.
    static func configured(for provider: Provider) -> HarnessChoice {
        switch provider {
        case .anthropic: return claude()
        case .openai: return codex()
        case .grok: return HarnessChoice()
        }
    }

    // Settings `env` keys that point claude at another provider.
    private static let claudeProviderKeys = ["ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"]

    // claude: `model` and `effortLevel` in settings.json.
    static func claude() -> HarnessChoice {
        guard let data = try? Data(contentsOf: CLIHome.file("settings.json", env: "CLAUDE_CONFIG_DIR", dir: ".claude")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return HarnessChoice()
        }
        let env = json["env"] as? [String: Any] ?? [:]
        let rerouted = claudeProviderKeys.contains { env[$0] != nil }
        return HarnessChoice(model: rerouted ? nil : nonEmpty(json["model"] as? String),
                      effort: nonEmpty(json["effortLevel"] as? String))
    }

    // codex: top-level `model` and `model_reasoning_effort` in config.toml.
    static func codex() -> HarnessChoice {
        guard let text = try? String(contentsOf: CLIHome.file("config.toml", env: "CODEX_HOME", dir: ".codex"),
                                     encoding: .utf8) else {
            return HarnessChoice()
        }
        let values = topLevelTOMLStrings(text)
        let otherProvider = values["model_provider"].map { $0 != "openai" } ?? false
        return HarnessChoice(model: otherProvider ? nil : nonEmpty(values["model"]),
                      effort: nonEmpty(values["model_reasoning_effort"]))
    }

    // The `key = "value"` (or 'value') string pairs before the first [table]
    // header, which is all these keys need; anything else in the file is ignored.
    static func topLevelTOMLStrings(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let raw = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard raw.count >= 2, let quote = raw.first, quote == "\"" || quote == "'",
                  let close = raw.dropFirst().firstIndex(of: quote) else { continue }
            values[key] = String(raw[raw.index(after: raw.startIndex)..<close])
        }
        return values
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

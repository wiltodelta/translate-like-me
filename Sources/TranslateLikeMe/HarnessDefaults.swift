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
    struct Choice: Equatable {
        var model: String?
        var effort: String?
    }

    // Settings `env` keys that point claude at another provider.
    private static let claudeProviderKeys = ["ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"]

    // claude: `model` and `effortLevel` in settings.json.
    static func claude() -> Choice {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.claude")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/settings.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Choice()
        }
        let env = json["env"] as? [String: Any] ?? [:]
        let rerouted = claudeProviderKeys.contains { env[$0] != nil }
        return Choice(model: rerouted ? nil : nonEmpty(json["model"] as? String),
                      effort: nonEmpty(json["effortLevel"] as? String))
    }

    // codex: top-level `model` and `model_reasoning_effort` in config.toml.
    static func codex() -> Choice {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
        guard let text = try? String(contentsOfFile: home + "/config.toml", encoding: .utf8) else {
            return Choice()
        }
        let values = topLevelTOMLStrings(text)
        let otherProvider = values["model_provider"].map { $0 != "openai" } ?? false
        return Choice(model: otherProvider ? nil : nonEmpty(values["model"]),
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

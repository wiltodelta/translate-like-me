import Foundation

// A model and reasoning effort for one CLI: a pick made in Settings, a CLI
// config default (HarnessDefaults), or the two resolved for a run. A nil field
// means "not set".
struct HarnessChoice: Equatable {
    var model: String?
    var effort: String?

    // The pick wins over the configured default. A pick is checked against the
    // catalog, which is only loaded then: an effort the resolved model does not
    // list is dropped (the CLI then uses its own default), so a stale pick or a
    // model switch never makes a run fail. With no pick, the user's own config
    // pairing passes through unchecked and no cache is read.
    static func resolve(picked: HarnessChoice, configured: HarnessChoice,
                        catalog: () -> HarnessCatalog) -> HarnessChoice {
        var choice = HarnessChoice(model: picked.model ?? configured.model,
                                   effort: picked.effort ?? configured.effort)
        if picked != HarnessChoice(), let effort = choice.effort,
           let allowed = catalog().efforts(for: choice.model), !allowed.contains(where: { $0.id == effort }) {
            choice.effort = nil
        }
        return choice
    }

    // What a run of `provider`'s CLI uses now.
    static func current(for provider: Provider) -> HarnessChoice {
        resolve(picked: Settings.harnessPick(for: provider),
                configured: HarnessDefaults.configured(for: provider),
                catalog: { HarnessModels.catalog(for: provider) })
    }
}

struct HarnessEffort: Equatable {
    let id: String
    let name: String
}

struct HarnessModel: Equatable {
    let id: String
    let name: String
    // In the CLI's own order; empty when the model takes no effort setting.
    let efforts: [HarnessEffort]
}

// The models a CLI offers, and the one it uses by default where it records that.
struct HarnessCatalog: Equatable {
    var models: [HarnessModel] = []
    var defaultModel: String?

    // The efforts `model` accepts, or nil when the model is not listed, so
    // callers never guess.
    func efforts(for model: String?) -> [HarnessEffort]? {
        models.first { $0.id == model }?.efforts
    }
}

// Each CLI's own model list, read from the cache the CLI keeps and refreshes:
// claude `~/.claude/cache/model-catalog/<account>-cc.json`, codex
// `$CODEX_HOME/models_cache.json`, grok `$GROK_HOME/models_cache.json`. These are
// internal files, parsed defensively: an unreadable one gives an empty catalog
// (claude falls back to its documented aliases), so Settings offers "Default"
// and a translation never depends on the format.
enum HarnessModels {
    static func catalog(for provider: Provider) -> HarnessCatalog {
        switch provider {
        case .anthropic:
            return newestClaudeCatalog().flatMap(parseClaude) ?? claudeAliases
        case .openai:
            return (try? Data(contentsOf: CLIHome.file("models_cache.json", env: "CODEX_HOME", dir: ".codex")))
                .map(parseCodex) ?? HarnessCatalog()
        case .grok:
            var catalog = (try? Data(contentsOf: CLIHome.file("models_cache.json", env: "GROK_HOME", dir: ".grok")))
                .map(parseGrok) ?? HarnessCatalog()
            catalog.defaultModel = Settings.grokDefaultModel
            return catalog
        }
    }

    // The aliases `claude --help` documents, which resolve to the latest model,
    // for when the catalog cannot be read; efforts are then unknown.
    static let claudeAliases = HarnessCatalog(models: [
        ("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")
    ].map { HarnessModel(id: $0.0, name: $0.1, efforts: []) })

    // claude's catalog: `catalog.config.models` entries with `id`, `name`, and
    // `thinking.effort_options` of `{id, name}`; `catalog.state.model` is the
    // model Claude Code uses by default.
    static func parseClaude(_ data: Data) -> HarnessCatalog? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let catalog = json["catalog"] as? [String: Any],
              let models = (catalog["config"] as? [String: Any])?["models"] as? [[String: Any]],
              !models.isEmpty else { return nil }
        let parsed = models.compactMap { model -> HarnessModel? in
            guard let id = model["id"] as? String else { return nil }
            let options = (model["thinking"] as? [String: Any])?["effort_options"] as? [[String: Any]] ?? []
            return HarnessModel(id: id, name: model["name"] as? String ?? id,
                                efforts: options.compactMap { effort($0["id"], name: $0["name"]) })
        }
        return HarnessCatalog(models: parsed,
                              defaultModel: (catalog["state"] as? [String: Any])?["model"] as? String)
    }

    // codex's cache: `models` entries with `slug`, `display_name`, `visibility`
    // ("hide" for internal ones), `priority`, and `supported_reasoning_levels` of
    // `{effort}` (no display names, so the ids are titled here).
    static func parseCodex(_ data: Data) -> HarnessCatalog {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return HarnessCatalog() }
        return HarnessCatalog(models: models
            .filter { ($0["visibility"] as? String) != "hide" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { model in
                guard let slug = model["slug"] as? String else { return nil }
                let levels = model["supported_reasoning_levels"] as? [[String: Any]] ?? []
                return HarnessModel(id: slug, name: model["display_name"] as? String ?? slug,
                                    efforts: levels.compactMap { effort($0["effort"], name: nil) })
            })
    }

    // grok's cache: `models` keyed by id, each with an `info` holding `id`,
    // `name`, `hidden`, and `reasoning_efforts` of `{value, label}`. The keys carry
    // no order, so the newest version comes first.
    static func parseGrok(_ data: Data) -> HarnessCatalog {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [String: Any] else { return HarnessCatalog() }
        return HarnessCatalog(models: models.values
            .compactMap { entry -> HarnessModel? in
                guard let info = (entry as? [String: Any])?["info"] as? [String: Any],
                      let id = info["id"] as? String, info["hidden"] as? Bool != true else { return nil }
                let efforts = info["reasoning_efforts"] as? [[String: Any]] ?? []
                return HarnessModel(id: id, name: info["name"] as? String ?? id,
                                    efforts: efforts.compactMap { effort($0["value"], name: $0["label"]) })
            }
            .sorted { $0.id.compare($1.id, options: .numeric) == .orderedDescending })
    }

    // `grok models` prints "Default model: grok-4.7" (grok 1.0.41, 2026-09-24).
    static func grokDefaultModel(in output: String) -> String? {
        output.split(separator: "\n").lazy
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("Default model:") else { return nil }
                let model = trimmed.dropFirst("Default model:".count).trimmingCharacters(in: .whitespaces)
                return model.isEmpty ? nil : model
            }
            .first
    }

    private static func effort(_ id: Any?, name: Any?) -> HarnessEffort? {
        guard let id = id as? String else { return nil }
        return HarnessEffort(id: id, name: name as? String ?? id.capitalized)
    }

    // Claude Code writes one catalog per signed-in account; the newest is the one
    // in use.
    private static func newestClaudeCatalog() -> Data? {
        let dir = CLIHome.file("cache/model-catalog", env: "CLAUDE_CONFIG_DIR", dir: ".claude")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files.filter { $0.lastPathComponent.hasSuffix("-cc.json") }.max { lhs, rhs in
            let date = { (url: URL) in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
            }
            return date(lhs) < date(rhs)
        }
        return newest.flatMap { try? Data(contentsOf: $0) }
    }
}

// A CLI's config directory: its override variable, else the dot directory in HOME.
enum CLIHome {
    static func file(_ name: String, env: String, dir: String) -> URL {
        let home = ProcessInfo.processInfo.environment[env] ?? (NSHomeDirectory() + "/" + dir)
        return URL(fileURLWithPath: home).appendingPathComponent(name)
    }
}

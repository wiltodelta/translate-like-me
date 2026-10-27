import Foundation

// A model and reasoning effort for one CLI: a pick made in Settings, a CLI
// config default (HarnessDefaults), or the two resolved for a run. A nil field
// means "not set".
struct HarnessChoice: Codable, Equatable {
    var model: String?
    var effort: String?
}

struct HarnessEffort: Equatable {
    let id: String
    let name: String
}

struct HarnessModel: Equatable {
    let id: String
    let name: String
    // nil: unknown; []: confirmed unsupported; otherwise the CLI's own order.
    var efforts: [HarnessEffort]?
    // The alias the CLI also accepts for this family ("opus"), nil where none.
    var alias: String?
}

// The models a CLI offers, and the one it uses by default where it records that.
struct HarnessCatalog: Equatable {
    var models: [HarnessModel] = []
    var defaultModel: String?

    // The listed model `id` names: by id, else the first (newest) model with
    // that alias, which is how claude resolves "opus" in a user's settings
    // (checked 2026-10-08: opus, sonnet, haiku and fable each ran the first
    // catalog model of their family).
    func model(_ id: String?) -> HarnessModel? {
        guard let id else { return nil }
        let alias = id.lowercased()
        return models.first { $0.id == id } ?? models.first { $0.alias == alias }
    }

    // nil also covers a listed model whose capabilities could not be read.
    func efforts(for model: String?) -> [HarnessEffort]? {
        self.model(model)?.efforts
    }
}

// Each CLI's own model list, read from the cache the CLI keeps and refreshes:
// claude `~/.claude/cache/model-catalog/<account>-cc.json`, codex
// `$CODEX_HOME/models_cache.json`, grok `$GROK_HOME/models_cache.json`; agy keeps
// none, so its list is the last `agy models` output (EngineStatus). These are
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
        case .antigravity:
            return Settings.antigravityModels.map(parseAntigravity) ?? HarnessCatalog()
        // Picked from LocalModel in Settings, not from a CLI's catalog.
        case .local:
            return HarnessCatalog()
        }
    }

    // The aliases `claude --help` documents, which resolve to the latest model,
    // for when the catalog cannot be read; efforts are then unknown.
    static let claudeAliases = HarnessCatalog(models: [
        ("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")
    ].map { HarnessModel(id: $0.0, name: $0.1, efforts: nil) })

    // claude's catalog: `catalog.config.models` entries with `id`, `name`,
    // `short_name` (the family, whose lowercase is its alias), and
    // `thinking.effort_options` of `{id, name}`; `catalog.state.model` is the
    // model Claude Code uses by default.
    static func parseClaude(_ data: Data) -> HarnessCatalog? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let catalog = json["catalog"] as? [String: Any],
              let models = (catalog["config"] as? [String: Any])?["models"] as? [[String: Any]],
              !models.isEmpty else { return nil }
        let parsed = models.compactMap { model -> HarnessModel? in
            guard let id = model["id"] as? String else { return nil }
            let options = (model["thinking"] as? [String: Any])?["effort_options"] as? [[String: Any]]
            return HarnessModel(id: id, name: model["name"] as? String ?? id,
                                efforts: efforts(options, id: "id", name: "name"),
                                alias: (model["short_name"] as? String)?.lowercased())
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
                let levels = model["supported_reasoning_levels"] as? [[String: Any]]
                return HarnessModel(id: slug, name: model["display_name"] as? String ?? slug,
                                    efforts: efforts(levels, id: "effort"))
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
                let levels = info["reasoning_efforts"] as? [[String: Any]]
                return HarnessModel(id: id, name: info["name"] as? String ?? id,
                                    efforts: efforts(levels, id: "value", name: "label"))
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

    // `agy models` prints "Fetching available models..." and then one
    // "<id>\t<name>" line per model and effort, the effort closing both
    // ("gemini-3.8-flash-low\tGemini 3.8 Flash (Low)", agy 1.4.2, 2026-10-19).
    // agy takes the model and effort apart (`--model gemini-3.8-flash --effort
    // low`, Medium when no effort is given) and refuses an effort a model is not
    // listed with, so the lines are grouped into one model per base id. A line
    // without that shape stays a model with no efforts. Which model agy uses by
    // default is not printed.
    static func parseAntigravity(_ output: String) -> HarnessCatalog {
        var models: [HarnessModel] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2, !fields[0].isEmpty, !fields[0].contains(" ") else { continue }
            var (id, name) = (fields[0], fields[1].isEmpty ? fields[0] : fields[1])
            var level: HarnessEffort?
            if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
                let label = String(name[open.upperBound..<name.index(before: name.endIndex)])
                let suffix = "-" + label.lowercased()
                if id.hasSuffix(suffix), id.count > suffix.count {
                    level = effort(label.lowercased(), name: label)
                    id = String(id.dropLast(suffix.count))
                    name = String(name[..<open.lowerBound])
                }
            }
            if let index = models.firstIndex(where: { $0.id == id }) {
                if let level { models[index].efforts?.append(level) }
            } else {
                models.append(HarnessModel(id: id, name: name, efforts: level.map { [$0] } ?? []))
            }
        }
        // agy lists Medium before High and Low.
        let order = ["low", "medium", "high", "xhigh", "max"]
        let rank = { (id: String) in order.firstIndex(of: id) ?? order.count }
        for index in models.indices { models[index].efforts?.sort { rank($0.id) < rank($1.id) } }
        return HarnessCatalog(models: models)
    }

    private static func effort(_ id: Any?, name: Any?) -> HarnessEffort? {
        guard let id = id as? String, !id.isEmpty else { return nil }
        return HarnessEffort(id: id, name: name as? String ?? id.capitalized)
    }

    // A partially changed schema cannot prove that an effort is unsupported.
    private static func efforts(_ entries: [[String: Any]]?, id: String,
                                name: String? = nil) -> [HarnessEffort]? {
        guard let entries else { return nil }
        let parsed = entries.compactMap { entry in effort(entry[id], name: name.flatMap { entry[$0] }) }
        return parsed.count == entries.count ? parsed : nil
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

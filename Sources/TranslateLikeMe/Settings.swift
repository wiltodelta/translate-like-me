import Foundation
import Security
import Carbon

enum Provider: String, CaseIterable {
    case anthropic
    case openai
    case grok
    case antigravity
    // A model running on this Mac (LocalEngine); it has no CLI, so the CLI
    // facts below are never read for it.
    case local

    // The CLI's product name, shown wherever an engine is named: the user picks,
    // installs and signs in to a CLI, not a plan, and agy serves Claude and
    // GPT-OSS models besides Gemini (decided 2026-10-19).
    var name: String {
        switch self {
        case .anthropic: return "Claude Code"
        case .openai: return "Codex"
        case .grok: return "Grok Build"
        case .antigravity: return "Antigravity"
        case .local: return String(localized: "Local model", comment: "The translation engine that runs on this Mac")
        }
    }

    var usesCLI: Bool { self != .local }

    var historySummary: String {
        switch self {
        case .anthropic, .openai:
            String(localized: "Translation and Rewrite use this engine. Session history is disabled.")
        case .grok:
            String(localized: "Translation and Rewrite use this engine. Grok Build may save text in its history.")
        case .antigravity:
            String(localized: "Translation and Rewrite use this engine. Antigravity saves text in its history.")
        case .local: ""
        }
    }

    var cliBinaryName: String {
        switch self {
        case .anthropic: return "claude"
        case .openai: return "codex"
        case .grok: return "grok"
        case .antigravity: return "agy"
        case .local: return ""
        }
    }

    // How "Default" picks the model, for Settings copy (HarnessDefaults).
    var modelSummary: String {
        switch self {
        case .anthropic: return String(localized: """
            Default reads the model and effort in your Claude Code settings. Custom providers are not inherited.
            """)
        case .openai: return String(localized: """
            Default reads the top-level model and effort in your Codex config. \
            Profiles and custom providers are not inherited.
            """)
        case .grok: return String(localized: "Default uses the model and effort from your Grok Build config.")
        case .antigravity: return String(localized: "Default uses the model selected in Antigravity.")
        case .local: return ""
        }
    }

    // How to sign in to the CLI, for the status menu's hint (verified against
    // each CLI's --help, 2026-09-23). agy has no login command: it signs in when
    // started without arguments (agy 1.4.2).
    var loginCommand: String {
        switch self {
        case .anthropic: return "claude auth login"
        case .openai: return "codex login"
        case .grok: return "grok login"
        case .antigravity: return "agy"
        case .local: return ""
        }
    }

    // The one sentence for a signed-out CLI, shared by the status menu row and the
    // translation popup so the two always give the same fix.
    var notSignedInHint: String {
        String(localized: "Not signed in to \(name). Run \(loginCommand) in Terminal.",
               comment: "The first placeholder is a command-line tool (Claude Code), the second a command to type")
    }

    // The status menu row's and onboarding's sentence for a missing CLI, or a
    // local model not downloaded yet.
    var notInstalledHint: String {
        guard usesCLI else { return LocalModelError.notDownloaded(Settings.localModel).localizedDescription }
        return String(localized: "The \(cliBinaryName) command-line tool (\(name)) was not found.",
                      comment: "The first placeholder is a command (claude), the second its product (Claude Code)")
    }

    // Extra environment for every run of this provider's CLI, translations and
    // status checks alike. grok (1.0.41, measured 2026-09-22) otherwise imports
    // ~/.claude and ~/.cursor rules, CLAUDE.md, skills, MCP servers and hooks,
    // injects memory and workflows, and may self-update mid-run; with the other
    // GrokAdapter flags in place, switching these off cut input tokens from ~17k to
    // ~5.7k and latency from ~7s to ~3.4s.
    var cliEnvironment: [String: String] {
        guard self == .grok else { return [:] }
        var env = ["GROK_MEMORY": "0", "GROK_WORKFLOWS": "0", "GROK_DISABLE_AUTOUPDATER": "1"]
        for vendor in ["CLAUDE", "CURSOR"] {
            for cell in ["AGENTS", "HOOKS", "MCPS", "RULES", "SKILLS"] {
                env["GROK_\(vendor)_\(cell)_ENABLED"] = "false"
            }
        }
        return env
    }

    // The CLI's sign-in probe (each fast, run off the main thread):
    //   claude: `auth status` prints JSON with "loggedIn": true on stdout.
    //   codex:  `login status` prints "Logged in ..." on STDERR, exit 0.
    //   grok:   has no status command; `models` prints "You are logged in with
    //           grok.com." or "You are not authenticated.", exit 0 either way
    //           (grok 1.0.41, ~0.9s).
    //   agy:    has no status command either; `models` lists the models, exit 0,
    //           or prints "Error: Please sign in to view available models.",
    //           exit 1 (agy 1.4.2, ~3s).
    var statusArguments: [String] {
        switch self {
        case .anthropic: return ["auth", "status"]
        case .openai: return ["login", "status"]
        case .grok, .antigravity: return ["models"]
        case .local: return []
        }
    }

    // Whether the sign-in probe's output also feeds Settings' model picker:
    // grok names its default model there, agy lists its models
    // (Settings.grokDefaultModel, Settings.antigravityModels).
    var probeReportsModels: Bool {
        switch self {
        case .grok, .antigravity: return true
        case .anthropic, .openai, .local: return false
        }
    }

    // `output` is stdout + stderr, lowercased.
    func isSignedIn(statusOutput output: String, exitCode: Int32) -> Bool {
        switch self {
        case .anthropic:
            return output.replacingOccurrences(of: " ", with: "").contains("\"loggedin\":true")
        case .openai:
            return exitCode == 0 && output.contains("logged in") && !output.contains("not logged in")
        case .grok:
            return exitCode == 0 && output.contains("you are logged in")
        case .antigravity:
            return exitCode == 0 && !output.contains("sign in")
        case .local:
            return true
        }
    }
}

// Thin wrapper over UserDefaults for the persisted settings.
enum Settings {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let provider = "provider"
        // Before styles moved into the pairs: one style for all, read only to migrate.
        static let style = "style"
        // capture-screenshots.sh overrides this key by name with sample pairs,
        // which also keeps the real styles out of the public screenshots.
        static let languagePairs = "languagePairs"
        // capture-screenshots.sh overrides this key by name too.
        static let rewritePresets = "rewritePresets"
        static let didCompleteFirstRun = "didCompleteFirstRun"
        static let grokDefaultModel = "grokDefaultModel"
        static let antigravityModels = "antigravityModels"
        // Before pairs: one pair and one shortcut, read only to migrate.
        static let languageA = "languageA"
        static let languageB = "languageB"
        static let replaceKeyCode = "replaceKeyCode"
        static let replaceModifiers = "replaceModifiers"
        // Prefixes, one key per provider (harnessModel.anthropic, ...).
        static let harnessModel = "harnessModel."
        static let harnessEffort = "harnessEffort."
    }

    static let dictationID = UUID(uuidString: "0452A428-00E5-4A44-9CB9-CEED213CC9DC")!

    static var dictationModel: DictationModel {
        get { DictationModel(rawValue: defaults.string(forKey: "dictationModel") ?? "") ?? .turbo }
        set { defaults.set(newValue.rawValue, forKey: "dictationModel") }
    }

    // The input dictation records from; nil follows the system input.
    static var dictationMicrophone: DictationMicrophone? {
        get {
            defaults.data(forKey: "dictationMicrophone")
                .flatMap { try? JSONDecoder().decode(DictationMicrophone?.self, from: $0) }
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "dictationMicrophone") }
    }

    // The model the local engine runs, picked in Settings > Translation.
    static var localModel: LocalModel {
        get { LocalModel(rawValue: defaults.string(forKey: "localModel") ?? "") ?? .default }
        set { defaults.set(newValue.rawValue, forKey: "localModel") }
    }

    static var dictationEnabled: Bool {
        get { defaults.bool(forKey: "dictationEnabled") }
        set { defaults.set(newValue, forKey: "dictationEnabled") }
    }

    static var dictationShortcut: KeyCombo? {
        get {
            if let data = defaults.data(forKey: "dictationShortcut") {
                guard let saved = try? JSONDecoder().decode(KeyCombo?.self, from: data) else { return nil }
                return Shortcut.isOptionOnly(saved) ? saved : KeyCombo(keyCode: 61, modifiers: Int(optionKey))
            }
            return KeyCombo(keyCode: 61, modifiers: Int(optionKey))
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "dictationShortcut") }
    }

    // The language pairs, each with its own optional shortcut, stored as JSON.
    // Seeded once for a new profile, otherwise read or migrated as stored.
    static var languagePairs: [LanguagePair] {
        get { storedPairs(in: defaults) ?? initialPairs() }
        set { storePairs(newValue, in: defaults) }
    }

    // The pairs as stored (possibly none), nil when nothing is stored yet.
    static func storedPairs(in store: UserDefaults) -> [LanguagePair]? {
        guard let data = store.data(forKey: Key.languagePairs) else { return nil }
        return try? JSONDecoder().decode([LanguagePair].self, from: data)
    }

    // The pairs before any are stored: the pre-pairs single pair for someone who
    // ran an earlier version, none for a new user, who sets them up in onboarding.
    static func initialPairs(in store: UserDefaults = .standard) -> [LanguagePair] {
        legacyPair(in: store).map { [$0] } ?? []
    }

    static func storePairs(_ pairs: [LanguagePair], in store: UserDefaults) {
        store.set(try? JSONEncoder().encode(pairs), forKey: Key.languagePairs)
    }

    // Rewrite presets stored as JSON. FirstRunRecommendations seeds a neutral
    // preset only for a new profile; a stored empty array keeps Rewrite off.
    static var rewritePresets: [RewritePreset] {
        get {
            guard let data = defaults.data(forKey: Key.rewritePresets) else { return [] }
            return (try? JSONDecoder().decode([RewritePreset].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.rewritePresets) }
    }

    static func rewritePreset(id: RewritePreset.ID) -> RewritePreset? {
        rewritePresets.first { $0.id == id }
    }

    // The default model `grok models` last reported (EngineStatus); a cache,
    // since grok's own config is not read.
    static var grokDefaultModel: String? {
        get { defaults.string(forKey: Key.grokDefaultModel) }
        set { defaults.set(newValue, forKey: Key.grokDefaultModel) }
    }

    // The last `agy models` listing (EngineStatus): agy keeps no model cache file
    // the app could read.
    static var antigravityModels: String? {
        get { defaults.string(forKey: Key.antigravityModels) }
        set { defaults.set(newValue, forKey: Key.antigravityModels) }
    }

    static func languagePair(id: LanguagePair.ID) -> LanguagePair? {
        languagePairs.first { $0.id == id }
    }

    // Set once onboarding (Settings, before onboarding existed) has been shown;
    // its presence also tells the pairs migration that an earlier version ran here.
    static var didCompleteFirstRun: Bool {
        get { defaults.bool(forKey: Key.didCompleteFirstRun) }
        set { defaults.set(newValue, forKey: Key.didCompleteFirstRun) }
    }

    // Writes the pairs once, so the first read's answer (the pre-pairs single
    // pair and shortcut, or none for a new user) never changes under a later
    // launch. Call first thing at launch.
    static func persistLanguagePairs() {
        guard defaults.data(forKey: Key.languagePairs) == nil else { return }
        languagePairs = languagePairs
    }

    // Gives every stored pair the one style an earlier version applied to all
    // translations, then removes it. Once any pair has a style of its own the
    // pairs are already set up, and an empty one is a deliberate plain pair, so
    // the old style is only removed. Call after persistLanguagePairs. Skipped
    // while the pairs are overridden for one launch (capture-screenshots.sh),
    // which would write the sample pairs back.
    static func moveStyleIntoPairs(in store: UserDefaults = .standard) {
        let overridden = store.volatileDomain(forName: UserDefaults.argumentDomain)
        guard overridden[Key.languagePairs] == nil, let style = store.string(forKey: Key.style) else { return }
        if var pairs = storedPairs(in: store), pairs.allSatisfy({ $0.trimmedStyle.isEmpty }),
           !style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for index in pairs.indices { pairs[index].style = style }
            storePairs(pairs, in: store)
        }
        store.removeObject(forKey: Key.style)
    }

    // The one pair and shortcut stored before pairs existed (defaults ru/en and
    // ⌥⌘F), for anyone who ran an earlier version; nil for a new user.
    static func legacyPair(in store: UserDefaults = .standard) -> LanguagePair? {
        let keys = [Key.languageA, Key.languageB, Key.replaceKeyCode, Key.replaceModifiers, Key.didCompleteFirstRun]
        guard keys.contains(where: { store.object(forKey: $0) != nil }) else { return nil }
        let code = store.object(forKey: Key.replaceKeyCode) as? Int ?? Languages.defaultShortcut.keyCode
        let mods = store.object(forKey: Key.replaceModifiers) as? Int ?? Languages.defaultShortcut.modifiers
        return LanguagePair(first: Languages.normalized(store.string(forKey: Key.languageA) ?? "ru"),
                            second: Languages.normalized(store.string(forKey: Key.languageB) ?? "en"),
                            shortcut: KeyCombo(keyCode: code, modifiers: mods))
    }

    static var provider: Provider {
        get { Provider(rawValue: defaults.string(forKey: Key.provider) ?? "") ?? .anthropic }
        set {
            defaults.set(newValue.rawValue, forKey: Key.provider)
            defaults.set(false, forKey: "automaticallySelectedProvider")
        }
    }

    static func canRecommendProvider(in store: UserDefaults = .standard) -> Bool {
        !store.bool(forKey: Key.didCompleteFirstRun)
            && (store.object(forKey: Key.provider) == nil || store.bool(forKey: "automaticallySelectedProvider"))
    }

    static func storeRecommendedProvider(_ provider: Provider, in store: UserDefaults = .standard) {
        store.set(provider.rawValue, forKey: Key.provider)
        store.set(true, forKey: "automaticallySelectedProvider")
    }

    // Removes what the API-key mode left behind once it was dropped: the auth
    // mode, the keys in the keychain (service = bundle id), and plain-text keys
    // from before the keychain. Call at launch.
    static func removeAPIKeys(from store: UserDefaults = .standard,
                              service: String = Bundle.main.bundleIdentifier ?? "com.wiltodelta.translatelikeme") {
        for key in ["authMode", "anthropicKey", "openaiKey"] { store.removeObject(forKey: key) }
        for account in ["anthropicKey", "openaiKey"] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service,
                                        kSecAttrAccount as String: account]
            SecItemDelete(query as CFDictionary)
        }
    }

    // The model and effort picked in Settings for a provider's CLI; a nil field
    // means "Default", the CLI config default (HarnessChoice).
    static func harnessPick(for provider: Provider) -> HarnessChoice {
        HarnessChoice(model: defaults.string(forKey: Key.harnessModel + provider.rawValue),
                      effort: defaults.string(forKey: Key.harnessEffort + provider.rawValue))
    }

    static func setHarnessPick(_ pick: HarnessChoice, for provider: Provider) {
        for (key, value) in [(Key.harnessModel, pick.model), (Key.harnessEffort, pick.effort)] {
            if let value { defaults.set(value, forKey: key + provider.rawValue) } else {
                defaults.removeObject(forKey: key + provider.rawValue)
            }
        }
    }
}

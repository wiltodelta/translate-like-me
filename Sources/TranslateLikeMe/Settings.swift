import Foundation

enum Provider: String, CaseIterable {
    case anthropic
    case openai
    case grok

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI"
        case .grok: return "xAI (Grok)"
        }
    }

    // Short friendly name for status rows ("Claude", not "Anthropic (Claude)").
    var shortName: String {
        switch self {
        case .anthropic: return "Claude"
        case .openai: return "ChatGPT"
        case .grok: return "Grok"
        }
    }

    var cliBinaryName: String {
        switch self {
        case .anthropic: return "claude"
        case .openai: return "codex"
        case .grok: return "grok"
        }
    }

    // The CLI's product name as users know it, for Settings copy.
    var cliProductName: String {
        switch self {
        case .anthropic: return "Claude Code"
        case .openai: return "Codex"
        case .grok: return "Grok"
        }
    }

    // How subscription mode picks the model, for Settings copy (HarnessDefaults).
    var subscriptionModelSummary: String {
        switch self {
        case .anthropic: return "Default uses the model and effort from your Claude Code settings."
        case .openai: return "Default uses the model and reasoning effort from your Codex config."
        case .grok: return "Default uses the model and effort from your Grok config."
        }
    }

    // How to sign in to the CLI, for the status menu's hint (verified against
    // each CLI's --help, 2026-09-23).
    var loginCommand: String {
        switch self {
        case .anthropic: return "claude auth login"
        case .openai: return "codex login"
        case .grok: return "grok login"
        }
    }

    // The API-key mode's settings copy, or nil for engines that run only through
    // their signed-in CLI (Grok has no direct xAI API mode here).
    // modelSummary says how API-key mode picks the model (ModelResolver).
    var apiKeyCopy: APIKeyCopy? {
        switch self {
        case .anthropic:
            return APIKeyCopy(header: "Claude API key", placeholder: "sk-ant-…",
                              help: "Create one at console.anthropic.com under API Keys.",
                              modelSummary: "Always picks the latest Sonnet automatically.")
        case .openai:
            return APIKeyCopy(header: "OpenAI API key", placeholder: "sk-…",
                              help: "Create one at platform.openai.com under API Keys.",
                              modelSummary: "Always picks the latest fast GPT automatically.")
        case .grok:
            return nil
        }
    }

    // Engine capabilities, so views and checks gate on the provider instead of
    // special-casing it by name.
    var supportsAPIKey: Bool { apiKeyCopy != nil }

    // The auth mode that applies: CLI-only engines ignore a stored API-key mode.
    func effectiveAuthMode(_ stored: AuthMode) -> AuthMode {
        supportsAPIKey ? stored : .subscription
    }

    // Extra environment for every run of this provider's CLI, translations and
    // status checks alike. grok (1.0.41, measured 2026-09-22) otherwise imports
    // ~/.claude and ~/.cursor rules, CLAUDE.md, skills, MCP servers and hooks,
    // injects memory and workflows, and may self-update mid-run; with the other
    // runGrok flags in place, switching these off cut input tokens from ~17k to
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
    var statusArguments: [String] {
        switch self {
        case .anthropic: return ["auth", "status"]
        case .openai: return ["login", "status"]
        case .grok: return ["models"]
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
        }
    }
}

struct APIKeyCopy {
    let header: String
    let placeholder: String
    let help: String
    let modelSummary: String
}

enum AuthMode: String, CaseIterable {
    case subscription
    case apiKey
}

// Thin wrapper over UserDefaults for the persisted settings.
enum Settings {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let provider = "provider"
        static let authMode = "authMode"
        // Before styles moved into the pairs: one style for all, read only to migrate.
        static let style = "style"
        static let anthropicKey = "anthropicKey"
        static let openaiKey = "openaiKey"
        // capture-screenshots.sh overrides this key by name with sample pairs,
        // which also keeps the real styles out of the public screenshots.
        static let languagePairs = "languagePairs"
        static let didCompleteFirstRun = "didCompleteFirstRun"
        static let grokDefaultModel = "grokDefaultModel"
        // Before pairs: one pair and one shortcut, read only to migrate.
        static let languageA = "languageA"
        static let languageB = "languageB"
        static let replaceKeyCode = "replaceKeyCode"
        static let replaceModifiers = "replaceModifiers"
        // Prefixes, one key per provider (harnessModel.anthropic, ...).
        static let harnessModel = "harnessModel."
        static let harnessEffort = "harnessEffort."
    }

    // The language pairs, each with its own optional shortcut, stored as JSON;
    // never empty.
    static var languagePairs: [LanguagePair] {
        get {
            storedPairs(in: defaults) ?? [legacyPair() ?? Languages.defaultPair(preferred: Locale.preferredLanguages)]
        }
        set { storePairs(newValue, in: defaults) }
    }

    // The pairs as stored, nil when none are.
    static func storedPairs(in store: UserDefaults) -> [LanguagePair]? {
        guard let data = store.data(forKey: Key.languagePairs),
              let pairs = try? JSONDecoder().decode([LanguagePair].self, from: data), !pairs.isEmpty else { return nil }
        return pairs
    }

    static func storePairs(_ pairs: [LanguagePair], in store: UserDefaults) {
        store.set(try? JSONEncoder().encode(pairs), forKey: Key.languagePairs)
    }

    // The default model `grok models` last reported (EngineStatus); a cache,
    // since grok's own config is not read.
    static var grokDefaultModel: String? {
        get { defaults.string(forKey: Key.grokDefaultModel) }
        set { defaults.set(newValue, forKey: Key.grokDefaultModel) }
    }

    static func languagePair(id: LanguagePair.ID) -> LanguagePair? {
        languagePairs.first { $0.id == id }
    }

    // Set once Settings has been shown on the first launch; its presence also
    // tells the pairs migration that an earlier version ran here.
    static var didCompleteFirstRun: Bool {
        get { defaults.bool(forKey: Key.didCompleteFirstRun) }
        set { defaults.set(newValue, forKey: Key.didCompleteFirstRun) }
    }

    // Writes the pairs once, so the first read's answer (the pre-pairs single
    // pair and shortcut, or the system languages for a new user) never changes
    // under a later launch. Call first thing at launch.
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
        set { defaults.set(newValue.rawValue, forKey: Key.provider) }
    }

    static var authMode: AuthMode {
        get { AuthMode(rawValue: defaults.string(forKey: Key.authMode) ?? "") ?? .subscription }
        set { defaults.set(newValue.rawValue, forKey: Key.authMode) }
    }

    // API keys live in the keychain (Keychain), never in the plain-text defaults.
    static var anthropicKey: String {
        get { Keychain.read(Key.anthropicKey) ?? "" }
        set { Keychain.write(newValue, for: Key.anthropicKey) }
    }

    static var openaiKey: String {
        get { Keychain.read(Key.openaiKey) ?? "" }
        set { Keychain.write(newValue, for: Key.openaiKey) }
    }

    // Moves API keys an earlier version kept in the defaults into the keychain
    // and removes the plain-text copies once the keychain holds a key (one
    // already there wins). Call at launch.
    static func moveAPIKeysToKeychain(from store: UserDefaults = .standard,
                                      service: String = Keychain.service) {
        for key in [Key.anthropicKey, Key.openaiKey] {
            guard let value = store.string(forKey: key) else { continue }
            if !value.isEmpty, Keychain.read(key, service: service) == nil {
                Keychain.write(value, for: key, service: service)
            }
            if value.isEmpty || Keychain.read(key, service: service) != nil {
                store.removeObject(forKey: key)
            }
        }
    }

    // MARK: - Derived accessors keyed by the active/selected provider

    static var effectiveAuthMode: AuthMode { provider.effectiveAuthMode(authMode) }

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

    static func apiKey(for provider: Provider) -> String {
        switch provider {
        case .anthropic: return anthropicKey
        case .openai: return openaiKey
        case .grok: return ""
        }
    }
}

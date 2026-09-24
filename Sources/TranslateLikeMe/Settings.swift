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
        // capture-screenshots.sh overrides this key by name, to keep the real
        // style out of the public screenshots.
        static let style = "style"
        static let anthropicKey = "anthropicKey"
        static let openaiKey = "openaiKey"
        // capture-screenshots.sh overrides this key by name with sample pairs.
        static let languagePairs = "languagePairs"
        static let didCompleteFirstRun = "didCompleteFirstRun"
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
            guard let data = defaults.data(forKey: Key.languagePairs),
                  let pairs = try? JSONDecoder().decode([LanguagePair].self, from: data), !pairs.isEmpty else {
                return [legacyPair() ?? Languages.defaultPair(preferred: Locale.preferredLanguages)]
            }
            return pairs
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.languagePairs) }
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

    // Custom writing style applied to the translation. Empty means plain translation.
    static var style: String {
        get { defaults.string(forKey: Key.style) ?? "" }
        set { defaults.set(newValue, forKey: Key.style) }
    }

    static var anthropicKey: String {
        get { defaults.string(forKey: Key.anthropicKey) ?? "" }
        set { defaults.set(newValue, forKey: Key.anthropicKey) }
    }

    static var openaiKey: String {
        get { defaults.string(forKey: Key.openaiKey) ?? "" }
        set { defaults.set(newValue, forKey: Key.openaiKey) }
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

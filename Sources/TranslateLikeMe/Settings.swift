import Foundation
import Security

enum Provider: String, CaseIterable {
    case anthropic
    case openai
    case grok

    // Short friendly name for status rows and Settings ("Claude", "ChatGPT").
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
        case .grok: return "Grok Build"
        }
    }

    // How "Default" picks the model, for Settings copy (HarnessDefaults).
    var modelSummary: String {
        switch self {
        case .anthropic: return "Default uses the model and effort from your Claude Code settings."
        case .openai: return "Default uses the model and reasoning effort from your Codex config."
        case .grok: return "Default uses the model and effort from your Grok Build config."
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

    // The one sentence for a signed-out CLI, shared by the status menu row and the
    // translation popup so the two always give the same fix.
    var notSignedInHint: String {
        "Not signed in to \(shortName). Run \(loginCommand) in Terminal."
    }

    // The status menu row's and onboarding's sentence for a missing CLI.
    var notInstalledHint: String {
        "The \(cliBinaryName) command-line tool (\(cliProductName)) was not found."
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

// Thin wrapper over UserDefaults for the persisted settings.
enum Settings {
    private static let defaults = UserDefaults.standard

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
        // Before pairs: one pair and one shortcut, read only to migrate.
        static let languageA = "languageA"
        static let languageB = "languageB"
        static let replaceKeyCode = "replaceKeyCode"
        static let replaceModifiers = "replaceModifiers"
        // Prefixes, one key per provider (harnessModel.anthropic, ...).
        static let harnessModel = "harnessModel."
        static let harnessEffort = "harnessEffort."
    }

    // The language pairs, each with its own optional shortcut, stored as JSON.
    // Empty for a new user until onboarding (or General > Languages) adds one.
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

    // The Rewrite presets, stored as JSON; none (the feature off) until the
    // user adds one in Settings > Rewrite.
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
        set { defaults.set(newValue.rawValue, forKey: Key.provider) }
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

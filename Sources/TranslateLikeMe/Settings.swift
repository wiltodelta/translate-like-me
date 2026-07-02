import Carbon
import Foundation

enum Provider: String, CaseIterable {
    case anthropic
    case openai

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI"
        }
    }

    var cliBinaryName: String {
        switch self {
        case .anthropic: return "claude"
        case .openai: return "codex"
        }
    }
}

enum AuthMode: String, CaseIterable {
    case subscription
    case apiKey

    var displayName: String {
        switch self {
        case .subscription: return "Subscription (official CLI)"
        case .apiKey: return "API key (direct API)"
        }
    }
}

// Thin wrapper over UserDefaults for the persisted settings.
enum Settings {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let provider = "provider"
        static let authMode = "authMode"
        static let style = "style"
        static let anthropicKey = "anthropicKey"
        static let openaiKey = "openaiKey"
        static let languageA = "languageA"
        static let languageB = "languageB"
        static let replaceKeyCode = "replaceKeyCode"
        static let replaceModifiers = "replaceModifiers"
    }

    // The two languages translated between. The app auto-detects which one the
    // input is and produces the other.
    static var languageA: String {
        get { defaults.string(forKey: Key.languageA) ?? "ru" }
        set { defaults.set(newValue, forKey: Key.languageA) }
    }

    static var languageB: String {
        get { defaults.string(forKey: Key.languageB) ?? "en" }
        set { defaults.set(newValue, forKey: Key.languageB) }
    }

    // Global hotkey to translate and replace the selection. Default: ⌥⌘F.
    static let defaultReplaceKeyCode = 3 // F
    static let defaultReplaceModifiers = Int(cmdKey | optionKey)

    static var replaceKeyCode: Int {
        get { value(Key.replaceKeyCode, default: defaultReplaceKeyCode) }
        set { defaults.set(newValue, forKey: Key.replaceKeyCode) }
    }

    static var replaceModifiers: Int {
        get { value(Key.replaceModifiers, default: defaultReplaceModifiers) }
        set { defaults.set(newValue, forKey: Key.replaceModifiers) }
    }

    private static func value(_ key: String, default fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
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

    static func apiKey(for provider: Provider) -> String {
        provider == .anthropic ? anthropicKey : openaiKey
    }

    static func setAPIKey(_ value: String, for provider: Provider) {
        if provider == .anthropic { anthropicKey = value } else { openaiKey = value }
    }
}

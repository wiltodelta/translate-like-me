import Observation

// Observable model for the settings panes. Every change is written to `Settings`
// (UserDefaults) and applied at once, the way macOS settings windows behave, so
// closing the window or switching panes never loses an edit.
@MainActor
@Observable
final class SettingsStore {
    var provider: Provider {
        didSet {
            Settings.provider = provider
            // Engines without an API-key mode (Grok) ignore the auth-mode split,
            // so keep the stored mode coherent for later switches back.
            if !provider.supportsAPIKey { authMode = .subscription }
            engineChanged()
        }
    }

    var authMode: AuthMode {
        didSet {
            Settings.authMode = authMode
            engineChanged()
        }
    }

    var style: String {
        didSet { Settings.style = style }
    }

    var replaceKeyCode: Int {
        didSet { shortcutChanged() }
    }

    var replaceModifiers: Int {
        didSet { shortcutChanged() }
    }

    var anthropicKey: String {
        didSet {
            Settings.anthropicKey = anthropicKey
            engineChanged()
        }
    }

    var openaiKey: String {
        didSet {
            Settings.openaiKey = openaiKey
            engineChanged()
        }
    }

    init() {
        provider = Settings.provider
        authMode = Settings.authMode
        style = Settings.style
        replaceKeyCode = Settings.replaceKeyCode
        replaceModifiers = Settings.replaceModifiers
        anthropicKey = Settings.anthropicKey
        openaiKey = Settings.openaiKey
    }

    // MARK: - Bindings scoped to the selected provider

    // The key field edits the selected provider's key (Settings.apiKey(for:)).
    var currentKey: String {
        get {
            switch provider {
            case .anthropic: return anthropicKey
            case .openai: return openaiKey
            case .grok: return ""
            }
        }
        set {
            switch provider {
            case .anthropic: anthropicKey = newValue
            case .openai: openaiKey = newValue
            case .grok: break
            }
        }
    }

    var effectiveAuthMode: AuthMode { provider.effectiveAuthMode(authMode) }

    // MARK: - Side effects

    // A model id may have been cached for the previous provider or key; clear it
    // so the next translation re-resolves the latest model live.
    private func engineChanged() {
        ModelResolver.clearCache()
    }

    private func shortcutChanged() {
        Settings.replaceKeyCode = replaceKeyCode
        Settings.replaceModifiers = replaceModifiers
        HotKeyManager.shared.reload()
    }
}

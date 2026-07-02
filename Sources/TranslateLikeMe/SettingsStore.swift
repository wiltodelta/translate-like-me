import Observation

// Observable editing model for the settings UI. Loads from `Settings`
// (UserDefaults) and writes back on save.
@MainActor
@Observable
final class SettingsStore {
    var provider: Provider
    var authMode: AuthMode
    var style: String

    var replaceKeyCode: Int
    var replaceModifiers: Int

    var anthropicKey: String
    var openaiKey: String

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

    var currentKey: String {
        get { provider == .anthropic ? anthropicKey : openaiKey }
        set { if provider == .anthropic { anthropicKey = newValue } else { openaiKey = newValue } }
    }

    // MARK: - Actions

    func save() {
        Settings.provider = provider
        Settings.authMode = authMode
        Settings.style = style
        Settings.replaceKeyCode = replaceKeyCode
        Settings.replaceModifiers = replaceModifiers
        Settings.anthropicKey = anthropicKey
        Settings.openaiKey = openaiKey

        // A model id may have been cached for the previous provider/key; clear it
        // so the next translation re-resolves the latest model live.
        ModelResolver.clearCache()

        // Apply the new shortcuts immediately.
        HotKeyManager.shared.reload()
    }
}

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
            loadPick()
        }
    }

    // The model and effort picked for the selected provider's CLI, a nil field
    // meaning "Default" (HarnessChoice); each provider keeps its own pick.
    var pick = HarnessChoice() {
        didSet { pickChanged() }
    }

    // The selected provider's models, and its CLI config defaults, which the
    // "Default" entries name.
    private(set) var catalog = HarnessCatalog()
    private(set) var configured = HarnessChoice()
    // Keeps loadPick's assignment from being saved back (or reset) as an edit.
    @ObservationIgnored private var loadingPick = false

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
        loadPick()
    }

    // The model "Default" runs: the CLI config default, else the CLI's own.
    var defaultModel: String? { configured.model ?? catalog.defaultModel }

    // The efforts the model in use accepts; empty when that model takes none or
    // is not known, so the Effort picker is hidden rather than guessed.
    var effortOptions: [HarnessEffort] {
        catalog.efforts(for: pick.model ?? defaultModel) ?? []
    }

    private func loadPick() {
        loadingPick = true
        defer { loadingPick = false }
        catalog = HarnessModels.catalog(for: provider)
        configured = HarnessDefaults.configured(for: provider)
        pick = Settings.harnessPick(for: provider)
    }

    private func pickChanged() {
        guard !loadingPick else { return }
        // A model change can leave an effort the new model does not accept; the
        // reset re-enters didSet, which saves.
        if let effort = pick.effort, let allowed = catalog.efforts(for: pick.model ?? defaultModel),
           !allowed.contains(where: { $0.id == effort }) {
            pick.effort = nil
            return
        }
        Settings.setHarnessPick(pick, for: provider)
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

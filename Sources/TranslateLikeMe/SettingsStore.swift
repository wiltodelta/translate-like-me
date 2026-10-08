import Foundation
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

    var pairs: [LanguagePair] {
        didSet {
            Settings.languagePairs = pairs
            // Hotkeys look their pair up when pressed, so a style or language
            // edit needs no re-registration.
            if oldValue.map(\.id) != pairs.map(\.id) || oldValue.map(\.shortcut) != pairs.map(\.shortcut) {
                HotKeyManager.shared.reload(pairs: pairs, presets: rewritePresets)
            }
        }
    }

    var rewritePresets: [RewritePreset] {
        didSet {
            Settings.rewritePresets = rewritePresets
            // Looked up when pressed too, so only ids and shortcuts matter here.
            if oldValue.map(\.id) != rewritePresets.map(\.id)
                || oldValue.map(\.shortcut) != rewritePresets.map(\.shortcut) {
                HotKeyManager.shared.reload(pairs: pairs, presets: rewritePresets)
            }
        }
    }

    init() {
        provider = Settings.provider
        pairs = Settings.languagePairs
        rewritePresets = Settings.rewritePresets
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
        if provider == .grok { refreshGrokDefault() }
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

    // grok's default model comes from running `grok models` (~1 s), so it is
    // asked off the main thread and the catalog reloaded when it answers.
    private func refreshGrokDefault() {
        Task {
            await Task.detached { EngineStatus.refreshGrokDefault() }.value
            guard provider == .grok else { return }
            catalog.defaultModel = Settings.grokDefaultModel
        }
    }

    // MARK: - Language pairs

    var canAddPair: Bool { pairs.count < Languages.maxPairs }

    func addPair() {
        guard canAddPair else { return }
        pairs.append(Languages.newPair(after: pairs))
    }

    func removePair(id: LanguagePair.ID) {
        pairs.removeAll { $0.id == id }
    }

    // What already uses `combo`, other than the pair or preset `id`, named for
    // the shortcut recorder, so one shortcut never triggers two actions.
    func owner(of combo: KeyCombo, except id: UUID) -> String? {
        pairs.first { $0.id != id && $0.shortcut == combo }.map(\.title)
            ?? rewritePresets.first { $0.id != id && $0.shortcut == combo }.map { "the \($0.title) preset" }
    }

    // MARK: - Rewrite presets

    var canAddRewritePreset: Bool { rewritePresets.count < Rewrite.maxPresets }

    func addRewritePreset() {
        guard canAddRewritePreset else { return }
        rewritePresets.append(Rewrite.newPreset(after: rewritePresets))
    }

    // Unlike the last pair, the last preset may go: Rewrite is simply off then.
    func removeRewritePreset(id: RewritePreset.ID) {
        rewritePresets.removeAll { $0.id == id }
    }
}

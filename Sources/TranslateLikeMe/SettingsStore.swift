import Combine
import Foundation
import Observation

// Observable model for the settings panes. Every change is written to `Settings`
// (UserDefaults) and applied at once, the way macOS settings windows behave, so
// closing the window or switching panes never loses an edit.
@MainActor
@Observable
final class SettingsStore {
    @ObservationIgnored private var recommendingProvider = false

    var provider: Provider {
        didSet {
            if recommendingProvider {
                Settings.storeRecommendedProvider(provider)
            } else {
                Settings.provider = provider
            }
            loadPick()
            if provider != oldValue { localConfigurationChanged() }
        }
    }

    // A switch releases the previous model before loading the next, since both
    // together can exceed memory.
    var localModel: LocalModel {
        didSet {
            guard localModel != oldValue else { return }
            Settings.localModel = localModel
            localConfigurationChanged()
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
    @ObservationIgnored private let refreshCatalog: (Provider) async -> Void
    @ObservationIgnored private var modelChanges: AnyCancellable?
    @ObservationIgnored private let localConfigurationChanged: () -> Void

    // An unchanged value is not stored: a field hands back its unchanged text when
    // it loses focus, and storing it rewrote the settings domain (a launch's
    // argument-domain values included) on every visit to a pane.
    var pairs: [LanguagePair] {
        didSet {
            guard pairs != oldValue else { return }
            Settings.languagePairs = pairs
            localConfigurationChanged()
            // Hotkeys look their pair up when pressed, so a style or language
            // edit needs no re-registration.
            if oldValue.map(\.id) != pairs.map(\.id) || oldValue.map(\.shortcut) != pairs.map(\.shortcut) {
                HotKeyManager.shared.reload(pairs: pairs, presets: rewritePresets)
            }
        }
    }

    var rewritePresets: [RewritePreset] {
        didSet {
            guard rewritePresets != oldValue else { return }
            Settings.rewritePresets = rewritePresets
            localConfigurationChanged()
            // Looked up when pressed too, so only ids and shortcuts matter here.
            if oldValue.map(\.id) != rewritePresets.map(\.id)
                || oldValue.map(\.shortcut) != rewritePresets.map(\.shortcut) {
                HotKeyManager.shared.reload(pairs: pairs, presets: rewritePresets)
            }
        }
    }

    init(refreshCatalog: @escaping (Provider) async -> Void = { await EngineStatus.refreshModels(for: $0) },
         localConfigurationChanged: @escaping () -> Void = {}) {
        self.localConfigurationChanged = localConfigurationChanged
        self.refreshCatalog = refreshCatalog
        provider = Settings.provider
        localModel = Settings.localModel
        pairs = Settings.languagePairs
        rewritePresets = Settings.rewritePresets
        modelChanges = NotificationCenter.default.publisher(for: .harnessModelsChanged)
            .sink { [weak self] notification in
                // EngineStatus publishes only on the main actor.
                MainActor.assumeIsolated {
                    guard let self, let asked = notification.object as? Provider, asked == self.provider else { return }
                    self.catalog = HarnessModels.catalog(for: asked)
                }
            }
        loadPick()
    }

    private(set) var didCheckInitialEngines = false

    func recommendWorkingEngine(health: [Provider: EngineHealth]) {
        guard FirstRunRecommendations.checksComplete(health) else { return }
        didCheckInitialEngines = true
        guard Settings.canRecommendProvider(),
              let working = FirstRunRecommendations.workingEngine(current: provider, health: health),
              working != provider else { return }
        selectRecommendedProvider(working)
    }

    func recommendLocalEngine() {
        guard Settings.canRecommendProvider(), provider != .local else { return }
        selectRecommendedProvider(.local)
    }

    private func selectRecommendedProvider(_ recommended: Provider) {
        recommendingProvider = true
        defer { recommendingProvider = false }
        provider = recommended
    }

    var resolution: HarnessResolution {
        HarnessResolution.resolve(picked: pick, configured: configured, catalog: catalog,
                                  requiresModelForEffort: provider == .antigravity)
    }

    var defaultModel: String? {
        HarnessResolution.resolve(picked: .init(), configured: configured, catalog: catalog).model
    }

    var defaultEffort: String? {
        HarnessResolution.resolve(picked: .init(model: pick.model), configured: configured, catalog: catalog,
                                  requiresModelForEffort: provider == .antigravity).choice.effort
    }

    var displayedEffort: String? {
        get { resolution.choice.effort == nil ? nil : pick.effort }
        set { pick.effort = newValue }
    }

    // Known options only. Unknown support can still show a preserved effort,
    // but never invents other values for the picker.
    var effortOptions: [HarnessEffort] {
        resolution.efforts ?? []
    }

    var showsEffortPicker: Bool {
        !effortOptions.isEmpty || (resolution.efforts == nil && resolution.choice.effort != nil)
    }

    // A saved alias can resolve in the catalog without being an exact picker
    // tag. Keep it selectable, including when the catalog is unavailable.
    var modelOptions: [HarnessModel] {
        var options = catalog.models
        if let picked = pick.model, !options.contains(where: { $0.id == picked }) {
            options.append(HarnessModel(id: picked, name: picked, efforts: catalog.efforts(for: picked)))
        }
        return options
    }

    private func loadPick() {
        loadingPick = true
        defer { loadingPick = false }
        catalog = HarnessModels.catalog(for: provider)
        if provider.probeReportsModels { refreshModels() }
        configured = HarnessDefaults.configured(for: provider)
        pick = Settings.harnessPick(for: provider)
    }

    private func pickChanged() {
        guard !loadingPick else { return }
        // Keep the preference even when a refreshed catalog cannot accept it.
        // The shared resolution suppresses incompatible launch flags without
        // rewriting a user's settings during a temporary cache failure.
        Settings.setHarnessPick(pick, for: provider)
    }

    // The sign-in probe takes ~1-3 s (Provider.probeReportsModels), so it runs
    // off the main thread. EngineStatus publishes the result to every open store.
    private func refreshModels() {
        let asked = provider
        let refresh = refreshCatalog
        Task {
            await refresh(asked)
        }
    }

    var dictationShortcut: KeyCombo? {
        get { Settings.dictationShortcut }
        set {
            Settings.dictationShortcut = newValue
            HotKeyManager.shared.reload()
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
    func owner(of combo: KeyCombo, except id: UUID) -> ShortcutOwner? {
        if id != Settings.dictationID, Settings.dictationShortcut == combo { return .dictation }
        return pairs.first { $0.id != id && $0.shortcut == combo }.map { .pair($0.title) }
            ?? rewritePresets.first { $0.id != id && $0.shortcut == combo }.map { .preset($0.title) }
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

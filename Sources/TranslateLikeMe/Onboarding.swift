import AppKit
import SwiftUI

// First launch applies recommendations, checks engines, and presents the result.
// Optional changes belong to Settings; microphone consent and downloads remain explicit.
@MainActor
enum Onboarding {
    static func makeWindow(store: SettingsStore, done: @escaping @MainActor () -> Void) -> NSWindow {
        let window = SettingsWindow(contentRect: .zero, styleMask: [.titled, .closable],
                                    backing: .buffered, defer: false)
        // A hosting view, not a hosting controller: a controller sizing the window
        // by preferredContentSize looped through layout passes until AppKit
        // aborted (measured 2026-10-05). Sized up front so center() sees the
        // real frame.
        // Synthetic engine health for native captures, without CLI or model calls.
        let preview = Bundle.main.bundleIdentifier == "com.wiltodelta.translatelikeme.dev"
            && UserDefaults.standard.bool(forKey: "onboardingPreview")
        let unavailable = UserDefaults.standard.bool(forKey: "onboardingNoEnginesPreview")
        let checks = preview ? EngineChecks(probe: { _ in unavailable ? .notInstalled : .working }) : EngineChecks()
        let content = NSHostingView(rootView: OnboardingView(store: store, checks: checks, done: done))
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.title = String(localized: "Welcome to Translate Like Me")
        return window
    }
}

// A finished download or changed model triggers another real local check.
private struct LocalChoice: Equatable {
    let model: LocalModel
    let ready: Bool
}

private struct OnboardingView: View {
    @Bindable var store: SettingsStore
    let done: @MainActor () -> Void
    @State private var checks: EngineChecks
    @State private var dictation = DictationController.shared
    @State private var localOffer: LocalModel?

    init(store: SettingsStore, checks: EngineChecks, done: @escaping @MainActor () -> Void) {
        self.store = store
        self.done = done
        _checks = State(initialValue: checks)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                configuration
                engine
                speech
            }
            .settingsPane(width: 520, reserved: 60)
            Divider()
            HStack {
                Button("Settings…") {
                    // Let the button's accessibility action finish before its
                    // window and hosting view are released.
                    DispatchQueue.main.async { [done] in
                        done()
                        NotificationCenter.default.post(name: .openSettings, object: nil)
                    }
                }
                .accessibilityIdentifier("onboarding.settings")
                Spacer()
                Button("Done", action: done)
                    .accessibilityIdentifier("onboarding.done")
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.didCheckInitialEngines)
            }
            .padding(16)
        }
        .onAppear {
            refreshLocalOffer()
            checkAll()
        }
        .onDisappear { checks.cancelAll() }
        .onChange(of: checks.health) { store.recommendWorkingEngine(health: checks.health) }
        .onChange(of: selectedLanguages) { refreshLocalOffer() }
        .onChange(of: store.pick) { checks.check(store.provider) }
        .onChange(of: LocalChoice(model: store.localModel,
                                  ready: LocalModelDownloads.shared.state(of: store.localModel) == .ready)) {
            checks.check(.local)
            refreshLocalOffer()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLocalOffer()
            for provider in Provider.allCases
            where [.notSignedIn, .notInstalled].contains(checks.health[provider]) {
                checks.check(provider)
            }
        }
    }

    private var configuration: some View {
        Section {
            if store.pairs.isEmpty {
                Text("No language pairs yet. Add one to get a translation shortcut.")
                    .foregroundStyle(Color.secondaryText)
            }
            ForEach(store.pairs) { pair in
                LabeledContent(pair.title) {
                    if let shortcut = pair.shortcut {
                        Text(Shortcut.display(shortcut)).foregroundStyle(Color.secondaryText)
                    }
                }
            }
        } header: {
            Text("Your starting setup").font(.title2.bold())
        } footer: {
            Text("""
                You can change languages and shortcuts in Settings.
                """)
                .foregroundStyle(Color.secondaryText)
        }
    }

    private var engine: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if !noWorkingEngine || !Settings.canRecommendProvider() {
                    EngineRow(provider: store.provider,
                              health: store.didCheckInitialEngines ? checks.health[store.provider] : .checking)
                }
                if !store.provider.usesCLI {
                    LocalModelControls(store: store, summary: store.localModel.downloadSummary)
                } else if noWorkingEngine, let model = localOffer {
                    LabeledContent("Local model") { Text(model.title).foregroundStyle(Color.secondaryText) }
                    Text(model.downloadSummary).foregroundStyle(Color.secondaryText)
                    Text("A local model can run without an account. A download is required before it can be tested.")
                        .foregroundStyle(Color.secondaryText)
                    Button("Download") {
                        store.localModel = model
                        store.provider = .local
                        LocalModelDownloads.shared.download(model)
                    }
                    .accessibilityIdentifier("onboarding.localDownload")
                }
                if noWorkingEngine {
                    Text("No engine is ready yet. Open Settings to choose a service or download a local model.")
                        .foregroundStyle(Color.secondaryText)
                    Button("Check Again") { Provider.allCases.forEach(checks.check) }
                }
            }
        } header: {
            Text("Translation")
        }
    }

    private var speech: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable dictation", isOn: Binding(get: { dictation.enabled }, set: { dictation.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                LabeledContent("Speech model") {
                    Text(dictation.model.title).foregroundStyle(Color.secondaryText)
                }
                Text(dictation.model.summary)
                    .foregroundStyle(Color.secondaryText)
                if let shortcut = store.dictationShortcut {
                    LabeledContent("Hold key") { Text(Shortcut.display(shortcut)).foregroundStyle(Color.secondaryText) }
                }
                DictationPreparationStatus(dictation: dictation)
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text("""
                Enable dictation to allow microphone access and download a speech model. You can also set it \
                up later in Settings.
                """)
                .foregroundStyle(Color.secondaryText)
        }
    }

    private var selectedLanguages: [String] {
        store.pairs.flatMap { [$0.first, $0.second] }.filter { !$0.isEmpty }
    }

    private var noWorkingEngine: Bool {
        FirstRunRecommendations.checksComplete(checks.health) && !checks.health.values.contains(.working)
    }

    private func refreshLocalOffer() {
        let selected = selectedLanguages
        let languages = selected.isEmpty ? Languages.systemSuggestions : selected
        localOffer = FirstRunRecommendations.availableLocalFallback(languages: languages)
    }

    private func checkAll() {
        for provider in Provider.allCases where checks.health[provider] == nil { checks.check(provider) }
    }
}

// A provider in the engine list with what its check found and, when it does not
// work, the fix.
private struct EngineRow: View {
    let provider: Provider
    let health: EngineHealth?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(provider.name)
            HStack(spacing: 4) {
                if health == .checking || health == nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: health == .working ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(health == .working ? .green : .orange)
                        .accessibilityHidden(true)
                }
                Text(detail)
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch health {
        case .checking, nil: return EngineStatus.checkingText
        case .working: return EngineStatus.readyText
        case .notInstalled: return provider.notInstalledHint
        case .notSignedIn: return provider.notSignedInHint
        case .limitReached(let message): return message
        case .failed(let message):
            return String(localized: "The test translation failed: \(message)",
                          comment: "The placeholder is the engine's own error message, often in English")
        }
    }
}

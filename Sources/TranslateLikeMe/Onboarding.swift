import AppKit
import SwiftUI

// First-launch setup: translation languages and engine, then optional local
// dictation. Translation can be skipped to set up dictation alone.
// Engines are checked only on their page, so dictation-only setup never invokes
// a translation service. Edits apply at once through the shared SettingsStore,
// like Settings; closing the window early keeps them.
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
        let checks = preview ? EngineChecks(probe: { _ in .working }) : EngineChecks()
        let content = NSHostingView(rootView: OnboardingView(store: store, checks: checks, done: done))
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.title = String(localized: "Welcome to Translate Like Me")
        return window
    }
}

private enum OnboardingStep: Equatable {
    case languages
    case engine
    case dictation
}

// One change, so picking an already downloaded model checks it once.
private struct LocalChoice: Equatable {
    let model: LocalModel
    let ready: Bool
}

private struct OnboardingView: View {
    @Bindable var store: SettingsStore
    let done: @MainActor () -> Void
    @State private var path: [OnboardingStep] = [.languages]
    @State private var checks: EngineChecks
    @State private var dictation = DictationController.shared
    // Until the user picks an engine, the first one that works is picked for them.
    @State private var userPicked = false

    init(store: SettingsStore, checks: EngineChecks, done: @escaping @MainActor () -> Void) {
        self.store = store
        self.done = done
        _checks = State(initialValue: checks)
    }

    private var step: OnboardingStep { path.last ?? .languages }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                switch step {
                case .languages: languagesStep
                case .engine: engineStep
                case .dictation:
                    DictationSetupSections(store: store, dictation: dictation, introductory: true)
                }
            }
            .settingsPane(width: 520, reserved: 60)
            Divider()
            buttons.padding(16)
        }
        .onChange(of: step) {
            if step == .engine {
                for provider in Provider.allCases where checks.health[provider] == nil { checks.check(provider) }
            } else {
                checks.cancelAll()
            }
        }
        .onDisappear { checks.cancelAll() }
        .onChange(of: checks.health) { pickWorkingEngine() }
        // A finished download, or another model picked, is tried like the rest.
        .onChange(of: LocalChoice(model: store.localModel,
                                  ready: LocalModelDownloads.shared.state(of: store.localModel) == .ready)) {
            if step == .engine { checks.check(.local) }
        }
        // Back from Terminal after `claude auth login` or an install: check those
        // again so the list catches up without a click. A check still running is
        // left alone, and a spent limit or failed run waits for Check Again,
        // since each recheck is a real translation.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard step == .engine else { return }
            for provider in Provider.allCases
            where [.notSignedIn, .notInstalled].contains(checks.health[provider]) {
                checks.check(provider)
            }
        }
    }

    // MARK: - Languages

    private var languagesStep: some View {
        Section {
            LanguagePairList(store: store)
        } header: {
            Text("Choose your language pairs").font(.title2.bold())
        } footer: {
            Text(LanguagePairList.explanation)
                .foregroundStyle(Color.secondaryText)
        }
    }

    // MARK: - Engine

    private var engineStep: some View {
        Section {
            Picker("Service", selection: Binding(
                get: { store.provider },
                set: { userPicked = true; store.provider = $0 }
            )) {
                ForEach(Provider.allCases, id: \.self) { provider in
                    EngineRow(provider: provider, health: checks.health[provider]).tag(provider)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if !store.provider.usesCLI {
                LocalModelControls(store: store)
            }
        } header: {
            Text("Choose a translation engine").font(.title2.bold())
        } footer: {
            Text("""
                Translate Like Me uses an AI subscription you already have, through the service's command-line \
                tool you are signed in to, or a model that runs on this Mac. Each one was tried with a short \
                test translation.
                """)
                .foregroundStyle(Color.secondaryText)
        }
    }

    private func checkAll() {
        Provider.allCases.forEach(checks.check)
    }

    // Only once the selected engine is known not to work: one still being
    // checked may work, and the user's earlier choice wins then.
    private func pickWorkingEngine() {
        guard !userPicked, let current = checks.health[store.provider], current != .checking, current != .working,
              let working = Provider.allCases.first(where: { checks.health[$0] == .working }) else { return }
        store.provider = working
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack {
            switch step {
            case .languages:
                Button("Skip Translation") { path.append(.dictation) }
                    .accessibilityIdentifier("onboarding.skipTranslation")
                Spacer()
                Button("Continue") { path.append(.engine) }
                    .accessibilityIdentifier("onboarding.continue")
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.pairs.isEmpty || !store.pairs.allSatisfy(\.isComplete))
            case .engine:
                Button("Back") { path.removeLast() }
                    .accessibilityIdentifier("onboarding.back")
                Button("Check Again", action: checkAll)
                    .disabled(Provider.allCases.contains { checks.health[$0] == .checking })
                Spacer()
                Button("Continue") { path.append(.dictation) }
                    .accessibilityIdentifier("onboarding.continue")
                    .keyboardShortcut(.defaultAction)
            case .dictation:
                Button("Back") { path.removeLast() }
                    .accessibilityIdentifier("onboarding.back")
                Spacer()
                Button("Done", action: done)
                    .accessibilityIdentifier("onboarding.done")
                    .keyboardShortcut(.defaultAction)
            }
        }
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

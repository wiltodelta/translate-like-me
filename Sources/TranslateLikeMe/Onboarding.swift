import AppKit
import SwiftUI

// The first-launch setup: the user adds their language pairs (a new user starts
// with none), then picks an engine from the ones that actually translate here.
// Every engine is checked as soon as the window opens (EngineChecks), so the
// results are in by the time the second step shows. Edits apply at once through
// the shared SettingsStore, like Settings; closing the window early keeps them.
enum Onboarding {
    static func makeWindow(store: SettingsStore, done: @escaping () -> Void) -> NSWindow {
        let window = SettingsWindow(contentRect: .zero, styleMask: [.titled, .closable],
                                    backing: .buffered, defer: false)
        // A hosting view, not a hosting controller: a controller sizing the window
        // by preferredContentSize looped through layout passes until AppKit
        // aborted (measured 2026-10-05). Sized up front so center() sees the
        // real frame.
        let content = NSHostingView(rootView: OnboardingView(store: store, done: done))
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.title = "Welcome to Translate Like Me"
        return window
    }
}

private enum OnboardingStep {
    case languages
    case engine
}

private struct OnboardingView: View {
    @Bindable var store: SettingsStore
    let done: () -> Void
    @State private var step = OnboardingStep.languages
    @State private var checks = EngineChecks()
    // Until the user picks an engine, the first one that works is picked for them.
    @State private var userPicked = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                switch step {
                case .languages: languagesStep
                case .engine: engineStep
                }
            }
            .settingsPane(width: 520, reserved: 60)
            Divider()
            buttons.padding(16)
        }
        .onAppear(perform: checkAll)
        .onDisappear { checks.cancelAll() }
        .onChange(of: checks.health) { pickWorkingEngine() }
        // Back from Terminal after `claude auth login` or an install: check those
        // again so the list catches up without a click. A check still running is
        // left alone, and a spent limit or failed run waits for Check Again,
        // since each recheck is a real translation.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
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
        } header: {
            Text("Choose a translation engine").font(.title2.bold())
        } footer: {
            Text("Translate Like Me uses an AI subscription you already have, through the service's "
                 + "command-line tool you are signed in to. Each one was tried with a short test translation.")
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
                Spacer()
                Button("Continue") { step = .engine }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.pairs.isEmpty)
            case .engine:
                Button("Back") { step = .languages }
                Button("Check Again", action: checkAll)
                    .disabled(Provider.allCases.contains { checks.health[$0] == .checking })
                Spacer()
                Button("Done", action: done)
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
            Text(provider.shortName)
            HStack(spacing: 4) {
                if health == .checking || health == nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: health == .working ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(health == .working ? .green : .orange)
                        .accessibilityHidden(true)
                }
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch health {
        case .checking, nil: return "Checking…"
        case .working: return "Ready"
        case .notInstalled: return provider.notInstalledHint
        case .notSignedIn: return provider.notSignedInHint
        case .limitReached(let message): return message
        case .failed(let message): return "The test translation failed: \(message)"
        }
    }
}

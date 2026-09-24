import SwiftUI

// The settings panes. HIG (Settings, macOS): a toolbar switches between panes,
// the window title follows the visible pane, and the window fits the pane, so
// nothing scrolls. Changes apply immediately (SettingsStore).
struct GeneralSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var updater = UpdateChecker.shared

    var body: some View {
        Form {
            shortcutSection
            startupSection
            updatesSection
        }
        .settingsPane()
    }

    // MARK: - Shortcut

    private var shortcutSection: some View {
        Section {
            LabeledContent("Translate selection") {
                ShortcutField(keyCode: $store.replaceKeyCode, modifiers: $store.replaceModifiers)
            }
        } header: {
            Text("Keyboard shortcut")
        } footer: {
            Text("Select text in any app, then press the shortcut to replace it with the "
                 + "translation. Click the shortcut to change it. Needs Accessibility "
                 + "permission (macOS will ask).")
        }
    }

    // MARK: - Startup

    private var startupSection: some View {
        Section {
            // HIG (Toggles, macOS): a mini switch for a single-row setting in a
            // grouped form keeps the row height consistent with other controls.
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: launchAtLogin) { LoginItem.set(launchAtLogin) }
        } header: {
            Text("Startup")
        } footer: {
            Text("Start Translate Like Me automatically when you log in to your Mac.")
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        Section {
            LabeledContent("Version", value: updater.version)
            Button {
                updater.checkForUpdates(manual: true)
            } label: {
                Text(updater.isChecking ? "Checking…" : "Check for Updates…")
            }
            .disabled(updater.isChecking)
        } header: {
            Text("Updates")
        } footer: {
            Text("Checks GitHub for a newer version on launch and offers to open the download page.")
        }
    }
}

struct TranslationSettingsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            styleSection
            engineSection
            if store.effectiveAuthMode == .apiKey, let copy = store.provider.apiKeyCopy {
                apiKeySection(copy)
            }
        }
        .settingsPane()
    }

    // MARK: - Writing style

    // A simple, neutral starter so the box isn't empty. Intentionally generic -
    // the user edits it into their own voice.
    private static let styleTemplate = """
    Friendly and casual, like a message to a colleague. Short, clear sentences. \
    Plain everyday words, no jargon or filler.
    """

    private var styleSection: some View {
        Section {
            TextEditor(text: $store.style)
                .font(.body)
                .frame(minHeight: 110, maxHeight: 220)
            if store.style.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Insert Starter Template") {
                    store.style = Self.styleTemplate
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        } header: {
            Text("Your writing style")
        } footer: {
            Text("Applied to every translation so it sounds like you. Describe the tone, "
                 + "for example: \"Casual and friendly, short sentences.\" "
                 + "Leave empty for a plain translation.")
        }
    }

    // MARK: - Engine

    private var engineSection: some View {
        Section {
            Picker("Service", selection: $store.provider) {
                Text("Claude").tag(Provider.anthropic)
                Text("ChatGPT").tag(Provider.openai)
                Text("Grok").tag(Provider.grok)
            }
            if store.provider.supportsAPIKey {
                Picker("How to connect", selection: $store.authMode) {
                    Text("Subscription").tag(AuthMode.subscription)
                    Text("API Key").tag(AuthMode.apiKey)
                }
            }
            if store.effectiveAuthMode == .subscription {
                modelPickers
            }
        } header: {
            Text("Translation engine")
        } footer: {
            Text(engineFooter)
        }
    }

    // The CLI's own models and efforts (HarnessModels); "Default" keeps the CLI
    // config default and names it when the app can read it.
    @ViewBuilder private var modelPickers: some View {
        Picker("Model", selection: $store.pick.model) {
            Text(Self.defaultLabel(store.defaultModel.map(modelName))).tag(String?.none)
            ForEach(store.catalog.models, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            // A pick the CLI no longer lists stays visible instead of blank.
            if let picked = store.pick.model, store.catalog.efforts(for: picked) == nil {
                Text(picked).tag(Optional(picked))
            }
        }
        if !store.effortOptions.isEmpty {
            Picker("Effort", selection: $store.pick.effort) {
                Text(Self.defaultLabel(store.configured.effort.map(effortName))).tag(String?.none)
                ForEach(store.effortOptions, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }
        }
    }

    private func modelName(_ id: String) -> String {
        store.catalog.models.first { $0.id == id }?.name ?? id
    }

    private func effortName(_ id: String) -> String {
        store.effortOptions.first { $0.id == id }?.name ?? id.capitalized
    }

    private static func defaultLabel(_ value: String?) -> String {
        value.map { "Default (\($0))" } ?? "Default"
    }

    private var engineFooter: String {
        let provider = store.provider
        if store.effectiveAuthMode == .subscription {
            return "Runs the \(provider.cliProductName) command-line tool you are signed in to "
                + "(not the desktop app). No extra cost beyond your plan. \(provider.subscriptionModelSummary)"
        }
        return "Connects directly with your own API key (you pay the provider per use). "
            + (provider.apiKeyCopy?.modelSummary ?? "")
    }

    // MARK: - API key

    private func apiKeySection(_ copy: APIKeyCopy) -> some View {
        Section {
            // HIG (Writing, text fields): label the field, hint the format.
            SecureField("Key", text: $store.currentKey, prompt: Text(copy.placeholder))
        } header: {
            Text(copy.header)
        } footer: {
            Text(copy.help)
        }
    }
}

private extension View {
    // A grouped form sized to its content at the settings window's width.
    func settingsPane() -> some View {
        formStyle(.grouped)
            .frame(width: 500)
            .fixedSize(horizontal: false, vertical: true)
    }
}

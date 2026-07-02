import SwiftUI

struct SettingsView: View {
    @State private var store = SettingsStore()
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            shortcutSection
            styleSection
            engineSection
            if store.authMode == .apiKey { apiKeySection }
            startupSection
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 640)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Save") {
                    store.save()
                    AppDelegate.shared?.closeSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(.bar)
        }
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
            Text("Select text in any app, then press the shortcut to replace it with the translation. Click the shortcut to change it. Needs Accessibility permission (macOS will ask).")
        }
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
                .frame(minHeight: 110)
            if store.style.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Insert a starter template") {
                    store.style = Self.styleTemplate
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        } header: {
            Text("Your writing style")
        } footer: {
            Text("Applied to every translation so it sounds like you. Describe the tone, for example: \"Casual and friendly, short sentences.\" Leave empty for a plain translation.")
        }
    }

    // MARK: - Engine

    private var engineSection: some View {
        Section {
            Picker("Service", selection: $store.provider) {
                Text("Claude").tag(Provider.anthropic)
                Text("ChatGPT").tag(Provider.openai)
            }
            Picker("How to connect", selection: $store.authMode) {
                Text("Use my subscription").tag(AuthMode.subscription)
                Text("Use an API key").tag(AuthMode.apiKey)
            }
        } header: {
            Text("Translation engine")
        } footer: {
            Text(engineFooter)
        }
    }

    private var engineFooter: String {
        let cli = store.provider == .anthropic ? "Claude Code" : "Codex"
        let latest = store.provider == .anthropic ? "Sonnet" : "GPT mini"
        if store.authMode == .subscription {
            return "Runs the \(cli) command-line tool you are signed in to (not the desktop app). No extra cost beyond your plan. Always picks the latest \(latest) automatically."
        }
        return "Connects directly with your own API key (you pay the provider per use). Always picks the latest \(latest) automatically."
    }

    // MARK: - API key

    private var apiKeySection: some View {
        Section {
            SecureField(store.provider == .anthropic ? "sk-ant-…" : "sk-…", text: $store.currentKey)
                .textFieldStyle(.roundedBorder)
        } header: {
            Text("\(store.provider == .anthropic ? "Claude" : "OpenAI") API key")
        } footer: {
            Text(store.provider == .anthropic
                 ? "Create one at console.anthropic.com under API Keys."
                 : "Create one at platform.openai.com under API Keys.")
        }
    }

    // MARK: - Startup

    private var startupSection: some View {
        Section {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { LoginItem.set(launchAtLogin) }
        } header: {
            Text("Startup")
        } footer: {
            Text("Start Translate Like Me automatically when you log in to your Mac.")
        }
    }
}

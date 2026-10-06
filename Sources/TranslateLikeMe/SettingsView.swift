import AppKit
import SwiftUI

// The settings panes. HIG (Settings, macOS): a toolbar switches between panes,
// the window title follows the visible pane, and the window fits the pane, so
// nothing scrolls (short screens aside, see settingsPane). Changes apply
// immediately (SettingsStore).
struct GeneralSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    @State private var updater = Updater.shared

    var body: some View {
        Form {
            languagesSection
            startupSection
            updatesSection
        }
        .settingsPane()
    }

    // MARK: - Languages

    private var languagesSection: some View {
        Section {
            LanguagePairList(store: store)
        } header: {
            Text("Languages")
        } footer: {
            Text(LanguagePairList.explanation + " Needs Accessibility permission (macOS will ask).")
        }
    }

    // MARK: - Startup

    private var startupSection: some View {
        Section {
            // HIG (Toggles, macOS): a mini switch for a single-row setting in a
            // grouped form keeps the row height consistent with other controls.
            // Shows what macOS actually did: a refused change flips back and says why.
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: {
                    loginItemError = LoginItem.set($0)
                    launchAtLogin = LoginItem.isEnabled
                }
            ))
                .toggleStyle(.switch)
                .controlSize(.mini)
        } header: {
            Text("Startup")
        } footer: {
            Text(loginItemError.map { "Couldn't change this: \($0)" }
                 ?? "Start Translate Like Me automatically when you log in to your Mac.")
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        Section {
            LabeledContent("Version", value: updater.version)
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.automaticallyChecks },
                set: { updater.automaticallyChecks = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            Button("Check for Updates…") { updater.checkForUpdates() }
        } header: {
            Text("Updates")
        } footer: {
            Text("Checks once a day and installs a new version when you choose to.")
        }
    }
}

struct TranslationSettingsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            engineSection
        }
        .settingsPane()
    }

    // MARK: - Engine

    private var engineSection: some View {
        Section {
            Picker("Service", selection: $store.provider) {
                Text("Claude").tag(Provider.anthropic)
                Text("ChatGPT").tag(Provider.openai)
                Text("Grok").tag(Provider.grok)
            }
            modelPickers
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
        return "Runs the \(provider.cliProductName) command-line tool you are signed in to "
            + "(not the desktop app). No extra cost beyond your plan. \(provider.modelSummary)"
    }
}

// The pair rows, one per pair with its own shortcut (up to Languages.maxPairs),
// and the Add Pair button; General > Languages and onboarding both show it.
struct LanguagePairList: View {
    @Bindable var store: SettingsStore

    static let explanation = "Select text in any app and press a pair's shortcut to replace it with "
        + "the translation. The source language is detected automatically; text in neither language is "
        + "translated into the first one. A pair's writing style makes its translations sound like you; "
        + "two pairs can share languages, one with your style and one without, for someone else's text."

    var body: some View {
        if store.pairs.isEmpty {
            Text("No language pairs yet. Add one to get a translation shortcut.")
                .foregroundStyle(.secondary)
        }
        ForEach($store.pairs) { $pair in
            LanguagePairRow(pair: $pair,
                            remove: { store.removePair(id: pair.id) },
                            usedBy: { store.pair(using: $0, except: pair.id)?.title })
        }
        // At the limit the button stays, disabled, and says why: a button
        // that silently vanished left people looking for it.
        HStack(spacing: 8) {
            Button("Add Pair") { store.addPair() }
                .disabled(!store.canAddPair)
            if !store.canAddPair {
                Text("Up to \(Languages.maxPairs) pairs")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// A language pair: two language pickers, the pair's shortcut, a
// remove button, and below them the pair's writing style as a one-line preview.
// The style is edited in a sheet, so a long voice guide never grows the pane
// (the settings window fits its pane and does not scroll).
private struct LanguagePairRow: View {
    @Binding var pair: LanguagePair
    let remove: () -> Void
    let usedBy: (KeyCombo) -> String?
    @State private var editingStyle = false

    var body: some View {
        let style = pair.trimmedStyle
        VStack(alignment: .leading, spacing: 6) {
            languagesRow
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(style.isEmpty ? "Plain translation, no writing style" : style)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Edit Style…") { editingStyle = true }
                    .accessibilityLabel("Edit the writing style for \(pair.title)")
            }
        }
        .sheet(isPresented: $editingStyle) {
            StyleEditor(pair: $pair)
        }
    }

    private var languagesRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            languagePicker("First language", isFirst: true)
            // Not a button: the direction is detected per translation.
            Text("↔").foregroundStyle(.secondary).accessibilityHidden(true)
            languagePicker("Second language", isFirst: false)
            Spacer(minLength: 8)
            ShortcutField(combo: $pair.shortcut, usedBy: usedBy)
            // The glyph stays small; its hit area does not. At the glyph's own
            // 13 pt it sat under HIG Accessibility's 20 pt macOS minimum, for the
            // one destructive control in the row. 24 pt keeps the row's height.
            Button(action: remove) {
                Image(systemName: "minus.circle")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Remove this pair")
            .accessibilityLabel("Remove \(pair.title)")
        }
    }

    private func languagePicker(_ label: String, isFirst: Bool) -> some View {
        LanguagePicker(label: label, code: isFirst ? pair.first : pair.second) {
            pair = Languages.setting(pair, first: isFirst, to: $0)
        }
        .equatable()
    }
}

// One side of a pair. Equatable on its code, so editing the pair's style does
// not rebuild a menu of every macOS language (300+ items) per keystroke.
private struct LanguagePicker: View, Equatable {
    let label: String
    let code: String
    let pick: (String) -> Void

    var body: some View {
        Picker(label, selection: Binding(get: { code }, set: pick)) {
            // A second language the Mac could not suggest waits for a pick.
            if code.isEmpty {
                Text("Choose a Language").tag("")
            }
            ForEach(Languages.all) { Text($0.name).tag($0.code) }
        }
        .labelsHidden()
        .fixedSize()
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.label == rhs.label && lhs.code == rhs.code }
}

// A pair's writing style in a sheet; edits apply as typed, like the rest of
// Settings. HIG (Sheets): a sheet for a focused task, dismissed with Done.
private struct StyleEditor: View {
    @Binding var pair: LanguagePair
    @Environment(\.dismiss) private var dismiss

    // A simple, neutral starter so the box isn't empty. Intentionally generic -
    // the user edits it into their own voice.
    private static let template = """
    Friendly and casual, like a message to a colleague. Short, clear sentences. \
    Plain everyday words, no jargon or filler.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Writing style for \(pair.title)")
                .font(.headline)
            // A visible field in both appearances: in light the editor's white
            // matched the sheet's, so an empty style showed only a caret.
            TextEditor(text: $pair.style)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .frame(height: 220)
            Text("Makes this pair's translations sound like you. Describe the tone, for example: "
                 + "\"Casual and friendly, short sentences.\" Leave empty for a plain translation, "
                 + "for example for someone else's text.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if pair.trimmedStyle.isEmpty {
                    Button("Insert Starter Template") { pair.style = Self.template }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

extension View {
    // A grouped form sized to its content at the settings window's width, but
    // never taller than the screen shows: past that the form scrolls. Three
    // language pairs made the General pane 777 pt, which already slid under the
    // Dock on a 1470x956 display and cannot fit a smaller one at all.
    // `reserved` is height the window takes below the form (onboarding's buttons).
    func settingsPane(width: CGFloat = 500, reserved: CGFloat = 0) -> some View {
        formStyle(.grouped)
            .frame(width: width)
            .frame(maxHeight: SettingsLayout.maxPaneHeight - reserved)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum SettingsLayout {
    // The window's title bar and pane toolbar take about 80 pt; 100 leaves a margin.
    static var maxPaneHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 100
    }
}

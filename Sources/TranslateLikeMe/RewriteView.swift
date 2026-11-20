import SwiftUI

// Rewrite has a pane of its own: under General > Languages, three pairs and
// three presets made the pane taller than a 1440x900 screen.
struct RewriteSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var bridge = BridgeClient.shared

    var body: some View {
        Form {
            Section {
                if store.rewritePresets.isEmpty {
                    Text("No presets yet. Add one to turn notes into a message.")
                        .foregroundStyle(Color.secondaryText)
                }
                ForEach(store.rewritePresets) { preset in
                    RewritePresetRow(preset: binding(for: preset),
                                     remove: { store.removeRewritePreset(id: preset.id) },
                                     usedBy: { store.owner(of: $0, except: preset.id) })
                }
                HStack(spacing: 8) {
                    Button("Add Preset") { store.addRewritePreset() }
                        .disabled(!store.canAddRewritePreset)
                    if !store.canAddRewritePreset {
                        Text("Up to \(Rewrite.maxPresets) presets")
                            .foregroundStyle(Color.secondaryText)
                    }
                }
            } header: {
                Text("Presets")
            } footer: {
                if AppEdition.current.showsDirectInsertionHelp(canInsertDirectly: bridge.canInsertDirectly) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("""
                            Use Services in the context menu on rough notes, or copy them and press a preset's \
                            shortcut, to turn them into a clear, finished message in the same language, in the \
                            preset's style. Every fact is kept, and questions stay questions for the recipient. \
                            Include a received message with your notes to reply to it. To send the message in \
                            another language, translate it afterwards. Uses the translation engine.
                            """)
                            .foregroundStyle(Color.secondaryText)
                        Link("Replacing Text in Place", destination: AppEdition.supportURL)
                    }
                } else {
                    Text("""
                        Select rough notes in any app, for example dictated, and press a preset's shortcut to \
                        replace them with a clear, finished message in the same language, in the preset's style. \
                        Every fact is kept, and questions stay questions for the recipient. Select a received \
                        message together with your notes to reply to it. To send the message in another language, \
                        translate it with a pair's shortcut afterwards. Uses the translation engine.
                        """)
                        .foregroundStyle(Color.secondaryText)
                }
            }
        }
        .settingsPane()
    }

    // The preset found by id, not by index: the row's name field reads its
    // binding once more after a removal, and `$store.rewritePresets`' index
    // binding then ran past the shortened array and crashed (2026-10-08).
    private func binding(for preset: RewritePreset) -> Binding<RewritePreset> {
        Binding(
            get: { store.rewritePresets.first { $0.id == preset.id } ?? preset },
            set: { edited in
                guard let index = store.rewritePresets.firstIndex(where: { $0.id == preset.id }) else { return }
                store.rewritePresets[index] = edited
            })
    }
}

// A Rewrite preset: its name, shortcut and a remove button, and below them its
// writing style as a one-line preview, drawn like a pair's row.
private struct RewritePresetRow: View {
    @Binding var preset: RewritePreset
    let remove: () -> Void
    let usedBy: (KeyCombo) -> ShortcutOwner?
    @State private var editingStyle = false

    var body: some View {
        let style = preset.trimmedStyle
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField("Name", text: $preset.name, prompt: Text("Preset name"))
                    .labelsHidden()
                    .accessibilityLabel("Preset name")
                    .frame(maxWidth: 200)
                Spacer(minLength: 8)
                ShortcutField(combo: $preset.shortcut, usedBy: usedBy, owner: .preset(preset.title))
                RemoveButton(help: "Remove this preset", label: "Remove the \(preset.title) preset", action: remove)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                (style.isEmpty ? Text("Clear, neutral message, no writing style") : Text(style))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Edit Style…") { editingStyle = true }
                    .accessibilityLabel("Edit the writing style for the \(preset.title) preset")
            }
        }
        .sheet(isPresented: $editingStyle) {
            StyleEditor(title: "Writing style for \(preset.title)", style: $preset.style,
                        hint: """
                            Makes this preset's messages sound like you. Describe the tone and any rules, for \
                            example: "Casual and friendly, short sentences, no emoji." Leave empty for a clear, \
                            neutral message.
                            """)
        }
    }
}

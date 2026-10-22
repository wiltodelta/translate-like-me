import AppKit
import SwiftUI

struct DictationSettingsView: View {
    let store: SettingsStore
    @State private var dictation = DictationController.shared

    var body: some View {
        Form {
            DictationSetupSections(store: store, dictation: dictation)
        }
        .settingsPane()
    }
}

// Settings and first-run setup share the same enable, shortcut and model flow.
struct DictationSetupSections: View {
    let store: SettingsStore
    let dictation: DictationController
    var introductory = false

    var body: some View {
        DictationControlsSection(store: store, dictation: dictation, introductory: introductory)
        DictationModelSection(dictation: dictation)
    }
}

private struct DictationControlsSection: View {
    let store: SettingsStore
    let dictation: DictationController
    let introductory: Bool

    var body: some View {
        Section {
            Toggle("Enable dictation", isOn: Binding(get: { dictation.enabled }, set: { dictation.setEnabled($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
            LabeledContent("Hold key") {
                ShortcutField(combo: Binding(get: { store.dictationShortcut },
                                             set: { store.dictationShortcut = $0 }),
                              usedBy: { store.owner(of: $0, except: Settings.dictationID) },
                              owner: .dictation,
                              requiresOptionOnly: true)
                    .disabled(!dictation.enabled || dictation.isActive)
            }
            DictationMicrophonePicker(dictation: dictation)
        } header: {
            if introductory {
                Text("Set up dictation").font(.title2.bold())
            } else {
                Text("Dictation")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if introductory {
                    Text("""
                        Enable dictation to allow microphone access and download a speech model. You can also set it \
                        up later in Settings.
                        """)
                }
                Text("Hold Option while speaking, then release to insert. Languages are detected automatically.")
            }
            .foregroundStyle(Color.secondaryText)
        }
    }
}

// System default first; a chosen device that is disconnected stays listed so
// the choice is visible, and recording uses the system input until it returns.
private struct DictationMicrophonePicker: View {
    let dictation: DictationController
    private let microphones = DictationMicrophones.shared

    var body: some View {
        Picker("Microphone", selection: Binding(get: { dictation.microphone?.uid }, set: { uid in
            dictation.selectMicrophone(uid.flatMap { uid in
                microphones.available.first { $0.uid == uid } ?? dictation.microphone
            })
        })) {
            if let name = microphones.systemName {
                Text("System default (\(name))").tag(String?.none)
            } else {
                Text("System default").tag(String?.none)
            }
            ForEach(microphones.available, id: \.uid) { Text($0.name).tag(Optional($0.uid)) }
            if let chosen = dictation.microphone, !microphones.available.contains(where: { $0.uid == chosen.uid }) {
                Text("\(chosen.name) (not connected)").tag(Optional(chosen.uid))
            }
        }
        .disabled(!dictation.enabled || dictation.isActive)
    }
}

private struct DictationModelSection: View {
    let dictation: DictationController
    @State private var managingModels = false
    private let downloads = DictationModelDownloads.shared

    var body: some View {
        Section {
            Picker("Model", selection: Binding(get: { dictation.model }, set: { dictation.selectModel($0) })) {
                ForEach(DictationModel.allCases) { model in
                    Text(model.title).tag(model)
                }
            }
            .disabled(dictation.isActive)
            Text(dictation.model.summary)
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    if !dictation.enabled || dictation.phase == .disabled {
                        ModelDownloadStatus(state: downloads.state(of: dictation.model))
                    } else {
                        DictationPreparationStatus(dictation: dictation)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Manage Models…") { managingModels = true }
                    .accessibilityIdentifier("manage-models")
            }
        } header: {
            Text("Speech model")
        } footer: {
            Text("""
                While dictation is enabled, the selected model downloads once and runs on your Mac. Downloaded \
                models are kept for later use.
                """)
                .foregroundStyle(Color.secondaryText)
        }
        .onAppear { downloads.refresh() }
        .onChange(of: dictation.phase) { downloads.refresh() }
        .sheet(isPresented: $managingModels) {
            ModelManagementView(title: String(localized: "Speech models"),
                footer: String(localized: """
                    To remove the selected model, choose another model or turn off dictation first.
                    """),
                models: DictationModel.allCases,
                name: { $0.title }, summary: { $0.summary }, selected: { $0 == dictation.model },
                state: { model in
                    if dictation.enabled && dictation.model == model && dictation.phase == .preparing {
                        return .preparing(dictation.progress)
                    }
                    return downloads.state(of: model)
                },
                canDownload: { _ in !downloads.isBusy && dictation.operation == nil && !dictation.isActive &&
                    dictation.phase != .preparing },
                canRemove: { !downloads.isBusy && dictation.operation == nil && !dictation.isActive &&
                    dictation.phase != .preparing &&
                    (!dictation.enabled || dictation.model != $0) },
                download: { downloads.download($0, controller: dictation) }, cancel: { downloads.cancel() },
                remove: { downloads.remove($0, controller: dictation) })
                .onAppear { downloads.refresh() }
        }
    }
}

struct DictationPreparationStatus: View {
    let dictation: DictationController

    var body: some View {
        if dictation.enabled {
            if dictation.phase == .preparing {
                if dictation.progress >= 1 {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Preparing for your Mac…").foregroundStyle(Color.secondaryText)
                    }
                } else {
                    ProgressView("Downloading speech model…", value: dictation.progress)
                        .accessibilityValue(Text(dictation.progress, format: .percent.precision(.fractionLength(0))))
                }
            } else if let error = dictation.error {
                Label {
                    Text(error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Button("Try Again") { dictation.prepare() }
            } else if dictation.phase == .ready {
                Text("Ready").foregroundStyle(Color.secondaryText)
            } else if dictation.phase == .cancelling {
                Text("Stopping the previous operation…").foregroundStyle(Color.secondaryText)
            }
        }
    }
}

struct DictationIndicatorContent: View {
    let phase: DictationSession.Phase
    let level: Double
    let cancel: () -> Void

    private var listening: Bool { phase == .recording }
    private var title: LocalizedStringKey {
        switch phase {
        case .recording: "Listening…"
        case .cancelling: "Cancelling…"
        default: "Recognizing…"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: listening ? "mic.fill" : "circle.dotted")
                .font(.title3)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.medium))
                if listening {
                    ProgressView(value: level)
                        .accessibilityLabel("Microphone level")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: cancel) {
                Image(systemName: "xmark").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel Dictation")
        }
        .padding(16)
        .frame(width: 280, height: 80)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct LiveDictationIndicator: View {
    let controller: DictationController
    var body: some View {
        DictationIndicatorContent(phase: controller.phase, level: controller.level, cancel: { controller.cancel() })
    }
}

private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DictationIndicator {
    static let shared = DictationIndicator()
    private var panel: DictationPanel?

    func show() { present(LiveDictationIndicator(controller: .shared)) }
    func hide() { panel?.orderOut(nil) }

    // Deterministic synthetic states for native capture, without opening a mic.
    func preview(_ phase: DictationSession.Phase) {
        present(DictationIndicatorContent(phase: phase, level: 0.55, cancel: { [weak self] in self?.hide() }))
    }

    private func present(_ content: some View) {
        if panel == nil {
            let window = DictationPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 80),
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
            window.title = String(localized: "Dictation")
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.hidesOnDeactivate = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = window
        }
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: content)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 140, y: frame.minY + 24))
        }
        panel.orderFrontRegardless()
    }
}

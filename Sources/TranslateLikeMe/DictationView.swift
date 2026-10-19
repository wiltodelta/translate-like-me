import AppKit
import SwiftUI

struct DictationSettingsView: View {
    let store: SettingsStore
    @State private var dictation = DictationController.shared

    var body: some View {
        Form {
            DictationControlsSection(store: store, dictation: dictation)
            DictationModelSection(dictation: dictation)
        }
        .settingsPane()
    }
}

private struct DictationControlsSection: View {
    let store: SettingsStore
    let dictation: DictationController

    var body: some View {
        Section {
            Toggle("Enable dictation", isOn: Binding(get: { dictation.enabled }, set: { dictation.setEnabled($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
            LabeledContent("Hold key") {
                ShortcutField(combo: Binding(get: { store.dictationShortcut },
                                             set: { store.dictationShortcut = $0 }),
                              usedBy: { store.owner(of: $0, except: Settings.dictationID) }, owner: "Dictation",
                              requiresOptionOnly: true)
                    .disabled(!dictation.enabled || dictation.isActive)
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text("Hold Option while speaking, then release to insert. "
                 + "Languages are detected automatically. Uses the microphone selected in macOS.")
                .foregroundStyle(Color.secondaryText)
        }
    }
}

private struct DictationModelSection: View {
    let dictation: DictationController

    var body: some View {
        Section {
            Picker("Model", selection: Binding(get: { dictation.model }, set: { dictation.selectModel($0) })) {
                ForEach(DictationModel.allCases) { model in
                    Text(model == .turbo ? "\(model.title) (Recommended)" : model.title).tag(model)
                }
            }
            .disabled(dictation.isActive)
            Text(dictation.model.summary)
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            DictationPreparationStatus(dictation: dictation)
        } header: {
            Text("Speech model")
        } footer: {
            Text("While dictation is enabled, the selected model downloads once and runs on your Mac. "
                 + "Downloaded models are kept for later use.")
                .foregroundStyle(Color.secondaryText)
        }
    }
}

private struct DictationPreparationStatus: View {
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
                        .accessibilityValue("\(Int(dictation.progress * 100)) percent")
                }
            } else if let error = dictation.error {
                Label {
                    Text(error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Button("Try Again") { dictation.prepare() }
            } else if dictation.phase == .ready {
                LabeledContent("Status") {
                    Text("Ready").foregroundStyle(Color.secondaryText)
                }
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
    private var title: String {
        switch phase {
        case .recording: "Listening…"
        case .recognizing: "Recognizing…"
        case .cancelling: "Cancelling…"
        default: "Preparing…"
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
            window.title = "Dictation"
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

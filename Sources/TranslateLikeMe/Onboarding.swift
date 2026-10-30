import AppKit
import SwiftUI

@MainActor
enum Onboarding {
    static func makeWindow(store: SettingsStore, done: @escaping @MainActor () -> Void) -> NSWindow {
        let window = SettingsWindow(contentRect: .zero, styleMask: [.titled, .closable],
                                    backing: .buffered, defer: false)
        let preview = Bundle.main.bundleIdentifier == "com.wiltodelta.translatelikeme.dev"
            && UserDefaults.standard.bool(forKey: "onboardingPreview")
        if !preview { store.recommendLocalEngine() }
        let stage = UserDefaults.standard.string(forKey: "onboardingStage") ?? "preparation"
        let flow = preview ? OnboardingFlow.preview(stage: stage)
            : OnboardingFlow(effects: .live(store: store))
        let content = NSHostingView(rootView: OnboardingView(store: store, flow: flow, done: done))
        window.contentView = content
        window.setContentSize(NSSize(width: 560, height: min(650, SettingsLayout.maxPaneHeight)))
        window.title = String(localized: "Welcome to Translate Like Me")
        return window
    }
}

struct OnboardingView: View {
    @Bindable var store: SettingsStore
    @State private var flow: OnboardingFlow
    let done: @MainActor () -> Void

    init(store: SettingsStore, flow: OnboardingFlow, done: @escaping @MainActor () -> Void) {
        self.store = store
        _flow = State(initialValue: flow)
        self.done = done
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "Translate Like Me").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondaryText).padding(.bottom, 24)
                switch flow.step {
                case .preparation: preparation
                case .permissions: permissions
                case .usage: usage
                }
            }
            .frame(maxWidth: .infinity, minHeight: 578, alignment: .topLeading)
            .padding(36)
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { flow.pause() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            flow.refreshPermissions()
        }
        .onChange(of: store.localModel) { flow.configurationChanged() }
        .onChange(of: store.provider) { flow.configurationChanged() }
        .onChange(of: DictationController.shared.model) { flow.configurationChanged() }
    }

    private var preparation: some View {
        Group {
            heading("Preparing your app", detail: """
                We chose local models for your Mac. Download them once to get started.
                """)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.pairs) { pair in
                    Label(pair.title, systemImage: "globe").font(.system(size: 14, weight: .medium))
                }
                if store.pairs.isEmpty || !store.pairs.allSatisfy(\.isComplete) {
                    Text("Choose your translation languages in Settings. We couldn't determine both from macOS.")
                        .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                    Button("Choose Languages…") { openSettings(.general) }
                } else {
                    Text("From macOS languages and keyboard layouts")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                }
            }.padding(.top, 20)
            VStack(alignment: .leading, spacing: 20) {
                OnboardingModelRow(symbol: "mic", title: "Dictation", name: Settings.dictationModel.title,
                         detail: Settings.dictationModel.summary, state: flow.speech,
                                   progress: speechProgress)
                OnboardingModelRow(symbol: "character.bubble", title: "Translation", name: store.localModel.title,
                         detail: store.localModel.downloadSummary, state: flow.translation,
                                   progress: translationProgress)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
            .padding(.top, 20)
            if store.provider != .local {
                LabeledContent("Translation engine") { Text(store.provider.name) }.font(.system(size: 13))
                    .padding(.top, 12)
            }
            if flow.running {
                ProgressView(value: preparationProgress).padding(.top, 20)
                    .accessibilityLabel("Model preparation")
            }
            errorMessage
            Spacer(minLength: 20)
            Text("We'll verify both models before asking for macOS permissions. Downloads can be resumed.")
                .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if flow.running {
                    Button("Pause") { flow.pause() }.accessibilityIdentifier("onboarding.pause")
                } else if !flow.modelsReady {
                    Button { flow.prepare() } label: { Text(downloadAction).primaryActionText() }
                        .onboardingPrimaryAction()
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("onboarding.download")
                    if flow.error != nil { Button("Settings…") { openSettings(.translation) } }
                }
                Spacer()
                Button { flow.continueFromPreparation() } label: {
                    Text("Continue").primaryActionText(enabled: flow.modelsReady)
                }
                    .onboardingPrimaryAction()
                    .keyboardShortcut(flow.modelsReady ? .defaultAction : nil)
                    .disabled(!flow.modelsReady || flow.running)
                    .accessibilityIdentifier("onboarding.continue")
            }.padding(.top, 20)
        }
    }

    private var permissions: some View {
        Group {
            heading("Access for dictation and text", detail: "Your models are ready.")
            VStack(alignment: .leading, spacing: 28) {
                permissionRow("mic", title: "Microphone",
                              detail: "For speech recognition while you hold the dictation key.",
                              ready: flow.microphone)
                permissionRow("hand.raised", title: "Accessibility",
                              detail: "To read selected text and insert results in the app you're using.",
                              ready: flow.accessibility, waiting: !flow.microphone)
            }.padding(.top, 34)
            errorMessage
            if flow.running {
                ProgressView().controlSize(.small).padding(.top, 12).accessibilityLabel("Model preparation")
            }
            Spacer(minLength: 20)
            Divider()
            Text(permissionExplanation).font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 20)
            Button { flow.permissionAction() } label: {
                Text(permissionAction).primaryActionText(enabled: !flow.running)
                    .frame(maxWidth: .infinity)
            }
            .onboardingPrimaryAction()
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: .infinity).padding(.top, 20)
            .disabled(flow.running).accessibilityIdentifier("onboarding.permission")
        }
    }

    private var usage: some View {
        Group {
            heading("Dictate, rewrite and translate",
                    detail: "Dictate into text fields. Rewrite rough notes and translate selected passages.")
            VStack(spacing: 28) {
                if let shortcut = store.dictationShortcut {
                    instruction("mic", title: "Dictate", shortcut: Shortcut.display(shortcut),
                                detail: """
                                    Place the cursor in a text field. Hold your dictation key, speak, then release it.
                                    """)
                } else {
                    setup("mic", title: "Dictate",
                          detail: "Set a dictation shortcut in Settings to dictate into text fields.",
                          action: "Set Dictation Shortcut…", pane: .dictation)
                }
                if let shortcut = store.rewritePresets.lazy.compactMap(\.shortcut).first {
                    instruction("text.bubble", title: "Rewrite notes", shortcut: Shortcut.display(shortcut),
                                detail: """
                                    Select rough notes and press your shortcut to replace them with a finished \
                                    message in the same language.
                                    """)
                } else if store.rewritePresets.isEmpty {
                    setup("text.bubble", title: "Rewrite notes",
                          detail: "Add a Rewrite preset in Settings to turn selected notes into a message.",
                          action: "Add a Rewrite Preset…", pane: .rewrite)
                } else {
                    setup("text.bubble", title: "Rewrite notes",
                          detail: "Set a Rewrite shortcut in Settings to turn selected notes into a message.",
                          action: "Set Rewrite Shortcut…", pane: .rewrite)
                }
                if let pair = store.pairs.first(where: { $0.isComplete && $0.shortcut != nil })
                    ?? store.pairs.first(where: \.isComplete) {
                    if let shortcut = pair.shortcut {
                        instruction("character.bubble", title: "Translate", shortcut: Shortcut.display(shortcut),
                                    detail: """
                                        Select text and press your shortcut. If insertion isn't available, copy the \
                                        translation from the result window.
                                        """)
                    } else {
                        setup("character.bubble", title: "Translate",
                              detail: "Set a translation shortcut in Settings to translate selected text.",
                              action: "Set Translation Shortcut…", pane: .general)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Choose your translation languages in Settings. We couldn't determine both from macOS.")
                            .foregroundStyle(Color.secondaryText)
                        Button("Choose Languages…") { openSettings(.general) }
                    }
                }
            }.padding(.top, 34)
            Spacer(minLength: 28)
            Divider()
            Text("""
                You can change models, languages and everything else in Settings. Open it from the \
                Translate Like Me icon in the menu bar.
                """)
                .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 20)
            Button {
                guard flow.finish() else { return }
                DispatchQueue.main.async { done() }
            } label: {
                Text("Start Using Translate Like Me").primaryActionText()
                    .frame(maxWidth: .infinity)
            }
            .onboardingPrimaryAction()
                .keyboardShortcut(.defaultAction)
            .frame(maxWidth: .infinity).padding(.top, 20)
            .accessibilityIdentifier("onboarding.done")
        }
    }

    private func heading(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 29, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.system(size: 15)).lineSpacing(4).foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(_ symbol: String, title: LocalizedStringKey,
                               detail: LocalizedStringKey, ready: Bool, waiting: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 24)).frame(width: 32, height: 34).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.system(size: 18, weight: .semibold))
                Text(detail).font(.system(size: 14)).lineSpacing(4).foregroundStyle(Color.secondaryText)
                if ready {
                    Label("Access granted", systemImage: "checkmark.circle.fill").font(.system(size: 13))
                } else if waiting {
                    Text("Next step").font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                } else {
                    Text("Permission required").font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // A feature whose shortcut or item is missing, with the button that sets it up.
    private func setup(_ symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey,
                       action: LocalizedStringKey, pane: SettingsPane) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            instruction(symbol, title: title, shortcut: nil, detail: detail)
            Button(action) { openSettings(pane) }
        }
    }

    private func instruction(_ symbol: String, title: LocalizedStringKey, shortcut: String?,
                             detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 24)).frame(width: 32, height: 34).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(title).font(.system(size: 18, weight: .semibold))
                    Spacer(minLength: 12)
                    if let shortcut {
                        Text(shortcut).font(.system(size: 13, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Text(detail).font(.system(size: 14)).lineSpacing(4).foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var errorMessage: some View {
        if let error = flow.error {
            Label {
                Text(error).foregroundStyle(Color.primary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
        }
    }

    private var downloadAction: LocalizedStringKey {
        flow.error == nil ? "Download Models" : "Try Again"
    }

    private var permissionAction: LocalizedStringKey {
        !flow.microphone && !flow.microphoneDenied || flow.permissionsReady ? "Continue" : "Open System Settings…"
    }

    private var permissionExplanation: LocalizedStringKey {
        if flow.permissionsReady { return "Both permissions are granted. Continue to see how to use the app." }
        if !flow.microphone && !flow.microphoneDenied {
            return "Continue opens the macOS microphone prompt. You decide whether to allow access."
        }
        return "Enable Translate Like Me in the system list, then return here."
    }

    private var preparationProgress: Double { (speechProgress + translationProgress) / 2 }

    private var speechProgress: Double {
        switch flow.speech {
        case .ready: 1
        case .working(let progress): progress
        default: 0
        }
    }

    private var translationProgress: Double {
        if flow.translation == .ready { return 1 }
        if flow.localDownloadState == .ready { return 1 }
        if case .downloading(let progress) = flow.localDownloadState { return progress }
        return 0
    }

    private func openSettings(_ pane: SettingsPane) {
        NotificationCenter.default.post(name: .openSettings, object: pane)
    }
}

private struct OnboardingModelRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let name: String
    let detail: String
    let state: OnboardingFlow.Preparation
    let progress: Double

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 23)).frame(width: 32, height: 34).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(name).font(.system(size: 14))
                Text(detail).font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                if state == .ready {
                    Label("Ready", systemImage: "checkmark.circle.fill").font(.system(size: 13))
                } else if state == .failed {
                    Label {
                        Text("Preparation failed").foregroundStyle(Color.primary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.system(size: 13))
                } else if case .working = state {
                    if progress >= 1 {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Checking…").font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                        }
                    } else {
                        ProgressView(value: progress)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private extension View {
    // White text on the standard button blue measured 4.02:1. Scope the
    // selection backing to primary buttons, preserving normal controls' colors.
    func onboardingPrimaryAction() -> some View {
        buttonStyle(.borderedProminent).controlSize(.large)
            .primaryActionTint()
    }
}

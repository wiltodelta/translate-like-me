import SwiftUI
import AppKit
import ApplicationServices
import Combine

// The window-style MenuBarExtra panel. Styling mirrors the Sleep Timer app:
// a centered intro, soft "primary.opacity" cards, compact status rows, and a
// plain secondary footer separated by a divider.
struct MenuContentView: View {
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var provider = Settings.provider
    @State private var authMode = Settings.authMode
    @State private var langA = Settings.languageA
    @State private var langB = Settings.languageB
    @State private var shortcut = Shortcut.display(keyCode: Settings.replaceKeyCode, modifiers: Settings.replaceModifiers)
    @State private var hasStyle = !Settings.style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    @State private var engineReady: EngineStatus.Readiness?
    @State private var engineCheckKey = ""

    // Settings is a plain UserDefaults wrapper, not observable, and this panel's
    // view can persist across opens without onAppear firing every time (seen with
    // Accessibility trust). So everything read from Settings is re-read on a
    // light timer, not just on appear, to stay in sync with the Settings window.
    private let recheck = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                languagesCard
                shortcutCard
                if !hasStyle { styleTipCard }
                statusCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 16)

            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear(perform: refresh)
        .onReceive(recheck) { _ in refresh() }
    }

    private func refresh() {
        accessibilityTrusted = AXIsProcessTrusted()
        provider = Settings.provider
        authMode = Settings.authMode
        langA = Settings.languageA
        langB = Settings.languageB
        shortcut = Shortcut.display(keyCode: Settings.replaceKeyCode, modifiers: Settings.replaceModifiers)
        hasStyle = !Settings.style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        refreshEngineIfNeeded()
    }

    // Re-check engine readiness only when the inputs that affect it change, so the
    // 2s refresh timer doesn't spawn a status subprocess every tick.
    private func refreshEngineIfNeeded() {
        let key = "\(provider.rawValue)|\(authMode.rawValue)|\(Settings.apiKey(for: provider).isEmpty)"
        guard key != engineCheckKey else { return }
        engineCheckKey = key
        Task {
            let result = await Task.detached { EngineStatus.check() }.value
            await MainActor.run { engineReady = result }
        }
    }

    // MARK: - Languages (on the first screen, not in Settings)

    private var languagesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Languages")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                languagePicker(selection: $langA)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                languagePicker(selection: $langB)
            }
            Text("No need to choose a direction. It is detected automatically.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private func languagePicker(selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            ForEach(Languages.all) { Text($0.name).tag($0.code) }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .onChange(of: selection.wrappedValue) { persistLanguages(changed: selection) }
    }

    // Keep the pair distinct and persist immediately.
    private func persistLanguages(changed: Binding<String>) {
        if langA == langB {
            let taken = changed.wrappedValue
            let other = Languages.all.first { $0.code != taken }?.code ?? taken
            if changed.wrappedValue == langA { langB = other } else { langA = other }
        }
        Settings.languageA = langA
        Settings.languageB = langB
    }

    // MARK: - Shortcut

    private var shortcutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard shortcut")
                .font(.system(size: 13, weight: .semibold))
            statusRow(icon: "arrow.2.squarepath", color: .accentColor,
                      title: "Translate selection",
                      detail: "Select text anywhere, then press \(shortcut).")
        }
        .card()
    }

    // MARK: - Writing-style tip (shown only when no style is set)

    private var styleTipCard: some View {
        Button {
            NotificationCenter.default.post(name: .openSettings, object: nil)
        } label: {
            statusRow(icon: "wand.and.stars", color: .accentColor,
                      title: "Add your writing style",
                      detail: "Set it in Settings so translations sound like you.")
                .card()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Status")
                .font(.system(size: 13, weight: .semibold))
            engineRow
            if !accessibilityTrusted {
                statusRow(icon: "exclamationmark.triangle.fill", color: .orange,
                          title: "Accessibility needed",
                          detail: "Enable Translate Like Me in System Settings, then relaunch.")
            }
        }
        .card()
    }

    private var providerName: String { provider == .anthropic ? "Claude" : "ChatGPT" }

    // Single combined engine row: the provider plus its proactive readiness (signed-
    // in check for subscription mode, key presence for API mode). Green when ready,
    // orange with a fix when not.
    @ViewBuilder private var engineRow: some View {
        let cli = provider == .anthropic ? "claude" : "codex"
        let using = authMode == .subscription ? "using your subscription" : "using your API key"
        switch engineReady {
        case .ready:
            statusRow(icon: "checkmark.circle.fill", color: .green,
                      title: providerName,
                      detail: "Signed in and ready, \(using).")
        case .notLoggedIn(let service):
            statusRow(icon: "exclamationmark.triangle.fill", color: .orange,
                      title: providerName,
                      detail: "Not signed in to \(service). Run \(cli) login in Terminal, then reopen this menu.")
        case .notInstalled(let name):
            statusRow(icon: "exclamationmark.triangle.fill", color: .orange,
                      title: providerName,
                      detail: "The \(name) command-line tool was not found. Install it and sign in.")
        case .noKey:
            statusRow(icon: "exclamationmark.triangle.fill", color: .orange,
                      title: providerName,
                      detail: "No API key yet. Add it in Settings.")
        case .none:
            statusRow(icon: "cpu", color: .secondary,
                      title: providerName,
                      detail: "Checking the connection…")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 16) {
            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // Compact status row, matching Sleep Timer.
    private func statusRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 18, height: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Card (Sleep Timer style)

private struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

private extension View {
    func card() -> some View { modifier(CardModifier()) }
}

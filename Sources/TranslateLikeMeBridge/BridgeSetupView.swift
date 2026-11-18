import SwiftUI
import TranslateLikeMeBridgeKit

struct BridgeSetupView: View {
    @Bindable var model: BridgeSetupModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Translate Like Me Bridge")
                    .font(.title2.bold())
                Text("""
                    Enables in-place text replacement, cursor-aware dictation, and Option-key hold for the Mac App \
                    Store edition of Translate Like Me.
                    """)
                    .font(.callout)
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 16) {
                accessibilityRow
                Divider()
                loginRow
            }
            .padding(16)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))

            if let error = model.loginItemError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            HStack {
                connectionStatus
                Spacer()
                if model.accessibilityTrusted {
                    Button("Done") { close() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        model.grantAccessibility()
                    } label: {
                        Text("Grant Accessibility…")
                            .primaryActionText()
                    }
                    .buttonStyle(.borderedProminent)
                    .primaryActionTint()
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var accessibilityRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised")
                .font(.system(size: 20))
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Accessibility")
                    .font(.headline)
                Text("Required to read selected text and paste results into the active window.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if model.accessibilityTrusted {
                    Label("Access granted", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                } else {
                    Text("Permission required")
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryText)
                }
            }
        }
    }

    private var loginRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "power")
                .font(.system(size: 18))
                .frame(width: 26, height: 24)
                .accessibilityHidden(true)
            Text("Launch at login")
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if !model.accessibilityTrusted {
            Text("Waiting for Accessibility permission")
                .font(.footnote)
                .foregroundStyle(Color.secondaryText)
        } else if model.connectedClients > 0 {
            Label("Connected to Translate Like Me", systemImage: "checkmark.circle.fill")
                .font(.footnote)
        } else {
            Text("Ready in background")
                .font(.footnote)
                .foregroundStyle(Color.secondaryText)
        }
    }
}

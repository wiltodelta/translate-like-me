import SwiftUI

// A row's remove control. The glyph stays small; its hit area does not. At the
// glyph's own 13 pt it sat under HIG Accessibility's 20 pt macOS minimum, for
// the one destructive control in the row. 24 pt keeps the row's height.
struct RemoveButton: View {
    let help: LocalizedStringKey
    let label: LocalizedStringKey
    let action: () -> Void
    @State private var confirmingRemoval = false
    @State private var removalConfirmed = false

    var body: some View {
        Button { confirmingRemoval = true } label: {
            Image(systemName: "minus.circle")
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label)
        .sheet(isPresented: $confirmingRemoval, onDismiss: {
            guard removalConfirmed else { return }
            removalConfirmed = false
            action()
        }, content: {
            RemovalConfirmation(title: label) {
                removalConfirmed = true
                confirmingRemoval = false
            }
        })
    }
}

// A normal sheet keeps confirmation buttons readable across system accents.
// NSAlert uses its own button tint, ignoring the content's contrast treatment.
struct RemovalConfirmation: View {
    let title: LocalizedStringKey
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text("Its shortcut and writing style will be deleted.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove", action: confirm)
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(width: 360)
    }
}

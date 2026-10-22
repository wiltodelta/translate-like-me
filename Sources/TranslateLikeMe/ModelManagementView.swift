import SwiftUI

// One download manager for translation and speech models. The owning service
// keeps work alive when this sheet closes.
struct ModelManagementView<Model: Identifiable>: View {
    let title: String
    var footer = ""
    let models: [Model]
    let name: (Model) -> String
    let summary: (Model) -> String
    let selected: (Model) -> Bool
    let state: (Model) -> ModelDownloadState
    let canDownload: (Model) -> Bool
    let canRemove: (Model) -> Bool
    let download: (Model) -> Void
    let cancel: () -> Void
    let remove: (Model) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: Model?
    @State private var confirmedRemoval: Model?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(models) { model in
                        row(model)
                        if model.id != models.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 12)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            if !footer.isEmpty {
                Text(footer).foregroundStyle(Color.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("models-done")
                    .keyboardShortcut(.defaultAction)
                    .primaryActionText()
                    .primaryActionTint()
            }
        }
        .onExitCommand { dismiss() }
        .padding(20)
        .frame(width: 520, height: models.count > 2 ? 560 : 440)
        .sheet(item: $pendingRemoval, onDismiss: {
            guard let model = confirmedRemoval else { return }
            confirmedRemoval = nil
            remove(model)
        }, content: { model in
            RemovalConfirmation(title: "Remove Download?",
                message: Text("\(name(model)) will be removed from this Mac. You can download it again later."),
                actionTitle: "Remove Download") {
                    confirmedRemoval = model
                    pendingRemoval = nil
                }
        })
    }

    private func row(_ model: Model) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(name(model)).fontWeight(.medium)
                Spacer(minLength: 12)
                if selected(model) {
                    Text("Selected").foregroundStyle(Color.secondaryText)
                }
            }
            Text(summary(model))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 12) {
                ModelDownloadStatus(state: state(model))
                    .frame(maxWidth: .infinity, alignment: .leading)
                action(model)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder private func action(_ model: Model) -> some View {
        switch state(model) {
        case .ready:
            Button("Remove Download") { pendingRemoval = model }
                .accessibilityIdentifier("remove-\(model.id)")
                .disabled(!canRemove(model))
                .accessibilityLabel(Text("\(String(localized: "Remove Download")): \(name(model))"))
        case .downloading:
            Button("Cancel", action: cancel)
                .accessibilityLabel(Text("\(String(localized: "Cancel")): \(name(model))"))
        case .removing, .preparing:
            ProgressView().controlSize(.small)
        default:
            Button("Download") { download(model) }.disabled(!canDownload(model))
                .accessibilityLabel(Text("\(String(localized: "Download")): \(name(model))"))
        }
    }
}

enum ModelDownloadState: Equatable {
    case notDownloaded
    case downloading(Double)
    case ready
    case removing
    case preparing(Double)
    case failed(String)
}

struct ModelDownloadStatus: View {
    let state: ModelDownloadState

    var body: some View {
        Group {
            switch state {
            case .notDownloaded: Text("Not downloaded")
            case .ready: Text("Downloaded")
            case .removing: Text("Removing…")
            case .preparing(let fraction): ProgressView("Preparing…", value: fraction)
            case .failed(let message): Text(message).fixedSize(horizontal: false, vertical: true)
            case .downloading(let fraction):
                ProgressView(value: fraction) {
                    Text("Downloading… \(fraction.formatted(.percent.precision(.fractionLength(0))))",
                         comment: "The placeholder is a percentage")
                }
            }
        }
        .foregroundStyle(Color.secondaryText)
    }
}

import SwiftUI

// The local engine's model picker and its download, in Settings > Translation
// and in onboarding when the local engine is chosen.
struct LocalModelControls: View {
    @Bindable var store: SettingsStore
    private let downloads = LocalModelDownloads.shared

    static var footer: String {
        String(localized: """
            Runs on this Mac: the text never leaves it, and translation works offline. The model downloads \
            once from Hugging Face. TranslateGemma is provided under the Gemma Terms of Use, Gemma 4 under \
            the Apache 2.0 license.
            """)
    }

    var body: some View {
        let model = store.localModel
        Picker("Model", selection: $store.localModel) {
            ForEach(LocalModel.allCases) { Text($0.title).tag($0) }
        }
        .disabled(downloads.isDownloading)
        Text(model.summary)
            .foregroundStyle(Color.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            status(of: model)
                .frame(maxWidth: .infinity, alignment: .leading)
            action(for: model)
        }
        .onAppear { downloads.refresh() }
    }

    @ViewBuilder private func status(of model: LocalModel) -> some View {
        if !downloads.fits(model) {
            Text(LocalModelError.insufficientMemory(model).localizedDescription)
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            switch downloads.state(of: model) {
            case .notDownloaded:
                Text("Not downloaded").foregroundStyle(Color.secondaryText)
            case .downloading(let fraction):
                ProgressView(value: fraction) {
                    Text("Downloading… \(fraction.formatted(.percent.precision(.fractionLength(0))))",
                         comment: "The placeholder is a percentage")
                        .foregroundStyle(Color.secondaryText)
                }
            case .ready:
                Text(EngineStatus.readyText).foregroundStyle(Color.secondaryText)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func action(for model: LocalModel) -> some View {
        switch downloads.state(of: model) {
        case .notDownloaded, .failed:
            Button("Download") { downloads.download(model) }
                .disabled(!downloads.fits(model) || downloads.isDownloading)
        case .downloading:
            Button("Cancel") { downloads.cancel() }
        case .ready:
            Button("Remove Download") { downloads.remove(model) }
        }
    }
}

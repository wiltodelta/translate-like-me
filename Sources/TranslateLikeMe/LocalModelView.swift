import SwiftUI

// The local engine's model picker and download manager in Settings > Translation.
struct LocalModelControls: View {
    @Bindable var store: SettingsStore
    var summary: String?
    @State private var managingModels = false
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
        Text(summary ?? model.summary)
            .foregroundStyle(Color.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            status(of: model)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Manage Models…") { managingModels = true }
                .accessibilityIdentifier("manage-models")
        }
        .onAppear { downloads.refresh() }
        .sheet(isPresented: $managingModels) {
            ModelManagementView(title: String(localized: "Translation models"), models: LocalModel.allCases,
                name: { $0.title }, summary: { $0.summary }, selected: { $0 == store.localModel },
                state: { downloads.state(of: $0) },
                canDownload: { downloads.fits($0) && !downloads.isDownloading },
                canRemove: { _ in true }, download: { downloads.download($0) },
                cancel: { downloads.cancel() }, remove: { downloads.remove($0) })
                .onAppear { downloads.refresh() }
        }
    }

    @ViewBuilder private func status(of model: LocalModel) -> some View {
        if !downloads.fits(model) {
            Text(LocalModelError.insufficientMemory(model).localizedDescription)
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            if downloads.state(of: model) == .ready {
                Text(EngineStatus.readyText).foregroundStyle(Color.secondaryText)
            } else {
                ModelDownloadStatus(state: downloads.state(of: model))
            }
        }
    }
}

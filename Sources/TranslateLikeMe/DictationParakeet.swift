import Foundation
import FluidAudio
@preconcurrency import WhisperKit

extension DictationEngine {
    static let parakeetSource = ModelDownloadConfig(modelRepo: "FluidInference/parakeet-ultra-coreml",
                                                    revision: "95eaa59a39d4394f047a4dc5cce480388a60d1b6")

    func prepareParakeet(in base: URL, download: Bool,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let source = Self.parakeetSource
        let components = ModelNames.ASR.requiredModelsV3(precision: .int8).sorted()
        let required = components.flatMap { component in
            ["coremldata.bin", "model.mil", "weights/weight.bin"].map { component + "/" + $0 }
        } + [ModelNames.ASR.vocabularyFile]
        let root = ModelDownloader(config: source).localRepoLocation(downloadBase: base)
        let snapshot = DictationSnapshot(root: root, revision: source.revision, variant: "", required: required)
        return try await snapshot.prepare(download: download) {
            let hub = HubApiWrapper(downloadBase: base, endpoint: source.endpoint)
            let patterns = components.map { $0 + "/*" } + [ModelNames.ASR.vocabularyFile]
            _ = try await hub.snapshot(from: .init(id: source.modelRepo), revision: source.revision,
                                       matching: patterns) { progress($0.fractionCompleted * 0.95) }
        }
    }
}

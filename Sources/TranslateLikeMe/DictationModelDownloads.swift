import Foundation
import Observation
import os
@preconcurrency import WhisperKit

// File-only management never requests microphone access or loads an ASR runtime.
// Engine preparation drains this service before touching the same snapshots.
@MainActor
@Observable
final class DictationModelDownloads {
    static let shared = DictationModelDownloads()
    private(set) var states: [DictationModel: ModelDownloadState] = [:]
    @ObservationIgnored private var task: (model: DictationModel, run: Task<Void, Never>)?
    @ObservationIgnored private let files: DictationModelFiles

    init(files: DictationModelFiles = .live) { self.files = files }

    var isBusy: Bool { task != nil }
    func state(of model: DictationModel) -> ModelDownloadState { states[model] ?? .notDownloaded }

    func refresh() {
        for model in DictationModel.allCases where task?.model != model {
            states[model] = files.isDownloaded(model) ? .ready : .notDownloaded
        }
    }

    func waitUntilIdle() async { await task?.run.value }
    func cancel() { task?.run.cancel() }

    func download(_ model: DictationModel, controller: DictationController) {
        guard !isBusy, controller.operation == nil, !controller.isActive, controller.phase != .preparing else { return }
        states[model] = .downloading(0)
        let run = Task {
            defer { task = nil }
            do {
                try await files.download(model) { value in
                    Task { @MainActor in
                        guard self.task?.model == model else { return }
                        self.states[model] = .downloading(value)
                    }
                }
                states[model] = .ready
            } catch let error where error is CancellationError || Task.isCancelled {
                states[model] = files.isDownloaded(model) ? .ready : .notDownloaded
            } catch {
                states[model] = .failed(error.localizedDescription)
                Logger.app("dictation").error("Model download failed: \(error, privacy: .public)")
            }
        }
        task = (model, run)
    }

    func remove(_ model: DictationModel, controller: DictationController) {
        guard !isBusy, controller.operation == nil, !controller.isActive, controller.phase != .preparing,
              !controller.enabled || controller.model != model else { return }
        states[model] = .removing
        let run = Task {
            defer { task = nil }
            await controller.unloadForModelRemoval()
            do {
                try files.remove(model)
                states[model] = .notDownloaded
            } catch {
                states[model] = .failed(error.localizedDescription)
                Logger.app("dictation").error("Model removal failed: \(error, privacy: .public)")
            }
        }
        task = (model, run)
    }
}

struct DictationModelFiles: Sendable {
    let base: URL
    static let live = DictationModelFiles(base: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.wiltodelta.translatelikeme.dev")
        .appendingPathComponent("Dictation", isDirectory: true))

    func root(for model: DictationModel) -> URL {
        ModelDownloader(config: model == .qwen3ASR ? DictationQwen.source : DictationEngine.modelSource)
            .localRepoLocation(downloadBase: base)
    }

    func folder(for model: DictationModel) -> URL {
        root(for: model).appendingPathComponent(model.variant, isDirectory: true)
    }

    // A fast presence check for the list. The engine still hashes every asset
    // before use; this status never substitutes for that integrity check.
    func isDownloaded(_ model: DictationModel) -> Bool {
        let required = DictationEngine.requiredFiles(for: model)
        let folder = folder(for: model)
        return required.allSatisfy { file in
            let values = try? folder.appendingPathComponent(file).resourceValues(forKeys: [.fileSizeKey])
            return (values?.fileSize ?? 0) > 0
        }
    }

    func download(_ model: DictationModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: base.path)
        guard let bytes = attributes[.systemFreeSize] as? NSNumber, bytes.int64Value >= 8_000_000_000 else {
            throw DictationError.insufficientStorage
        }
        let engine = DictationEngine(directory: base)
        _ = try await engine.prepareModels(model: model, in: base, download: true, progress: progress)
        if model.tokenizer != nil {
            _ = try await engine.prepareTokenizer(model: model, in: base, download: true, progress: progress)
        }
        _ = try await engine.prepareSpeechDetector(in: base, download: true) { progress(0.95 + $0 * 0.05) }
        try Task.checkCancellation()
    }

    func remove(_ model: DictationModel) throws {
        // Whisper variants share their repository, and every model shares VAD.
        // Delete only this variant and its own tokenizer, keeping neighbors.
        var targets = [folder(for: model)]
        if model != .qwen3ASR {
            targets.append(root(for: model).appendingPathComponent(".cache/huggingface/download/" + model.variant))
        }
        if let tokenizer = model.tokenizer {
            targets.append(ModelDownloader(config: ModelDownloadConfig(modelRepo: tokenizer.repository,
                revision: tokenizer.revision)).localRepoLocation(downloadBase: base))
        }
        for target in targets where FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }
}

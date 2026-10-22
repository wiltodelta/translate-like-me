import Foundation
import Observation
import os

private let log = Logger.app("local")

// The local models' download state, which Settings and onboarding show. A
// Settings download continues while its window is closed; onboarding can pause
// its pending download explicitly. One model downloads at a time.
@MainActor
@Observable
final class LocalModelDownloads {
    static let shared = LocalModelDownloads()

    typealias State = ModelDownloadState
    typealias Removal = @MainActor (LocalModel) async throws -> Void

    private(set) var states: [LocalModel: State] = [:]
    @ObservationIgnored private var task: (model: LocalModel, run: Task<Void, Never>)?
    @ObservationIgnored private var removing: Set<LocalModel> = []
    @ObservationIgnored private let files = LocalModelFiles.live
    @ObservationIgnored private let removeModel: Removal

    init(removeModel: @escaping Removal = { try await LocalEngine.shared.remove($0) }) {
        self.removeModel = removeModel
        refresh()
    }

    func state(of model: LocalModel) -> State { states[model] ?? .notDownloaded }

    // A model this Mac cannot run is not offered for download.
    func fits(_ model: LocalModel) -> Bool { model.fits(physicalMemory: ProcessInfo.processInfo.physicalMemory) }

    var isDownloading: Bool { task != nil }

    // Reads what is on disk; a running download keeps its progress.
    func refresh() {
        for model in LocalModel.allCases where task?.model != model && !removing.contains(model) {
            states[model] = files.isInstalled(model) ? .ready : .notDownloaded
        }
    }

    func download(_ model: LocalModel, verify: Bool = false) {
        guard task == nil, !removing.contains(model), fits(model), verify || state(of: model) != .ready else { return }
        states[model] = .downloading(0)
        log.notice("Local model \(model.rawValue, privacy: .public) download started")
        let run = Task {
            do {
                try await files.download(model) { fraction in
                    Task { @MainActor in
                        guard case .downloading = self.states[model] else { return }
                        self.states[model] = .downloading(fraction)
                    }
                }
                states[model] = .ready
                log.notice("Local model \(model.rawValue, privacy: .public) downloaded and verified")
            } catch let error where error is CancellationError || Task.isCancelled {
                states[model] = .notDownloaded
            } catch {
                states[model] = .failed(error.localizedDescription)
                log.error("Local model \(model.rawValue, privacy: .public) download failed: \(error, privacy: .public)")
            }
            task = nil
        }
        task = (model, run)
    }

    // Keeps the files fetched so far; the next download resumes from them.
    func cancel() {
        task?.run.cancel()
    }

    // Onboarding waits for verified files before running the real engine check.
    func downloadAndWait(_ model: LocalModel) async throws {
        guard fits(model) else { throw LocalModelError.insufficientMemory(model) }
        download(model, verify: true)
        guard let task, task.model == model else {
            throw LocalModelError.downloadFailed(String(localized: "The model download could not start."))
        }
        await task.run.value
        try Task.checkCancellation()
        guard state(of: model) == .ready else {
            if case .failed(let message) = state(of: model) { throw LocalModelError.downloadFailed(message) }
            throw CancellationError()
        }
    }

    func canRemove(_ model: LocalModel, selected: LocalModel) -> Bool {
        model != selected && task?.model != model && !removing.contains(model)
    }

    func remove(_ model: LocalModel) {
        // Recheck the current selection: it may have changed since confirmation opened.
        guard canRemove(model, selected: Settings.localModel) else { return }
        removing.insert(model)
        states[model] = .removing
        Task {
            defer { removing.remove(model) }
            do {
                try await removeModel(model)
                states[model] = .notDownloaded
            } catch {
                states[model] = .failed(error.localizedDescription)
                log.error("Local model \(model.rawValue, privacy: .public) removal failed: \(error, privacy: .public)")
            }
        }
    }
}

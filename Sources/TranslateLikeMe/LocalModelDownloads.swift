import Foundation
import Observation
import os

private let log = Logger.app("local")

// The local models' download state, which Settings and onboarding show. A
// download continues while the window is closed; one model downloads at a time.
@MainActor
@Observable
final class LocalModelDownloads {
    static let shared = LocalModelDownloads()

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var states: [LocalModel: State] = [:]
    @ObservationIgnored private var task: (model: LocalModel, run: Task<Void, Never>)?
    @ObservationIgnored private var removing: Set<LocalModel> = []
    @ObservationIgnored private let files = LocalModelFiles.live

    init() { refresh() }

    func state(of model: LocalModel) -> State { states[model] ?? .notDownloaded }

    // A model this Mac cannot run is not offered for download.
    func fits(_ model: LocalModel) -> Bool { model.fits(physicalMemory: ProcessInfo.processInfo.physicalMemory) }

    var isDownloading: Bool { task != nil }

    // Reads what is on disk; a running download keeps its progress.
    func refresh() {
        for model in LocalModel.allCases where task?.model != model {
            states[model] = files.isInstalled(model) ? .ready : .notDownloaded
        }
    }

    func download(_ model: LocalModel) {
        guard task == nil, !removing.contains(model), fits(model), state(of: model) != .ready else { return }
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

    func remove(_ model: LocalModel) {
        guard task?.model != model, removing.insert(model).inserted else { return }
        Task {
            defer { removing.remove(model); refresh() }
            do {
                try await LocalEngine.shared.remove(model)
            } catch {
                log.error("Local model \(model.rawValue, privacy: .public) removal failed: \(error, privacy: .public)")
            }
        }
    }
}

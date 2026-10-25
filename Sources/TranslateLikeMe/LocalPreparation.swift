import Foundation
import os

// Background preparation owns no microphone and never downloads missing assets.
// Replacing a configuration cancels and drains its preparation before the next.
@MainActor
final class LocalPreparation {
    static let shared = LocalPreparation()
    private(set) var operation: Task<Void, Never>?
    private let prepare: @Sendable (LocalModel, [String]) async throws -> Void
    private let release: @Sendable () async -> Void
    private let sleep: @Sendable () async throws -> Void

    init(
        prepare: @escaping @Sendable (LocalModel, [String]) async throws -> Void = {
            try await LocalEngine.shared.prepare(model: $0, systems: $1)
        },
        release: @escaping @Sendable () async -> Void = {
            await LocalEngine.shared.releaseIfIdle(reason: "engine changed")
        },
        sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(300)) }
    ) {
        self.prepare = prepare
        self.release = release
        self.sleep = sleep
    }

    static func refreshSelected() {
        let model = Settings.didCompleteFirstRun && Settings.provider == .local ? Settings.localModel : nil
        shared.update(model: model, pairs: Settings.languagePairs, presets: Settings.rewritePresets)
    }

    func update(model: LocalModel?, pairs: [LanguagePair], presets: [RewritePreset]) {
        let previous = operation
        previous?.cancel()
        let prepare = prepare
        let release = release
        let sleep = sleep
        operation = Task {
            await previous?.value
            do {
                try Task.checkCancellation()
                guard let model else { await release(); return }
                // Coalesce edits to language and style fields before running MLX.
                try await sleep()
                try Task.checkCancellation()
                // Match PromptHeads' budget, prioritizing translation pairs.
                let limit = LocalEngine.promptHeadLimit
                let systems = pairs.prefix(limit).map { Translator.systemPrompt(pair: $0) }
                    + presets.prefix(max(0, limit - pairs.count)).map { Rewrite.systemPrompt(preset: $0) }
                let started = ContinuousClock.now
                try await prepare(model, systems)
                try Task.checkCancellation()
                let elapsed = started.duration(to: .now)
                Logger.app("local").notice("Local translation prepared in \(elapsed, privacy: .public)")
            } catch is CancellationError {
                return
            } catch LocalModelError.notDownloaded {
                return
            } catch {
                Logger.app("local").warning("Local preparation failed: \(error, privacy: .public)")
            }
        }
    }
}

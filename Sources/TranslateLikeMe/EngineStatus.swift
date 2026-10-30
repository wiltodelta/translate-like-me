import Foundation

// Checks whether an engine is ready to translate: a missing CLI, a signed-out
// account or an undownloaded local model. EngineProbe builds on it for onboarding.
//
// The checks are cheap: a filesystem lookup for the CLI, and `claude auth status`
// / `codex login status` (each ~0.1-0.2s) / `grok models` (~0.9s) / `agy models`
// (~3s). Run off the main thread.
enum EngineStatus {
    static var readyText: String { String(localized: "Ready", comment: "Engine or dictation status") }

    enum Readiness: Equatable {
        case ready
        case notInstalled
        case notLoggedIn
        case failed(String)
    }

    // The engine chosen in Settings by default; onboarding checks each one. The
    // local model is ready once its download is verified (LocalModelFiles).
    static func check(provider: Provider) async -> Readiness {
        guard provider.usesCLI else {
            let model = Settings.localModel
            return localReadiness(model: model, installed: LocalModelFiles.live.isInstalled(model),
                                  physicalMemory: ProcessInfo.processInfo.physicalMemory)
        }
        guard let binary = await Translator.binaryPath(name: provider.cliBinaryName) else {
            return .notInstalled
        }
        return await readiness(binary: binary, provider: provider)
    }

    static func localReadiness(model: LocalModel, installed: Bool, physicalMemory: UInt64) -> Readiness {
        guard model.fits(physicalMemory: physicalMemory) else {
            return .failed(LocalModelError.insufficientMemory(model).localizedDescription)
        }
        return installed ? .ready : .notInstalled
    }

    // Some CLIs keep what Settings' model picker needs where the app cannot
    // read it: grok its default model (for the "Default (…)" label and Effort
    // picker), agy its model list. Their sign-in probe prints it, so the probe
    // records it (Provider.probeReportsModels). Off the main thread.
    static func refreshModels(for provider: Provider) async {
        guard provider.usesCLI, let binary = await Translator.binaryPath(name: provider.cliBinaryName) else { return }
        _ = await readiness(binary: binary, provider: provider)
    }

    static func readiness(binary: String, provider: Provider) async -> Readiness {
        do {
            let result = try await ProcessRunner.run(
                binary: binary, arguments: provider.statusArguments,
                environment: Translator.toolEnvironment(adding: provider.cliEnvironment),
                deadline: ProcessRunner.deadline(after: 10))
            let output = result.stdout + result.stderr
            var recordedModels = false
            if provider == .grok, let model = HarnessModels.grokDefaultModel(in: output) {
                Settings.grokDefaultModel = model
                recordedModels = true
            }
            if provider == .antigravity, result.status == 0 {
                Settings.antigravityModels = result.stdout
                recordedModels = true
            }
            if recordedModels {
                // A menu or onboarding probe can finish after Settings opened.
                // Publish on the main actor so its existing store refreshes too.
                await MainActor.run {
                    NotificationCenter.default.post(name: .harnessModelsChanged, object: provider)
                }
            }
            return provider.isSignedIn(statusOutput: output.lowercased(), exitCode: result.status)
                ? .ready : .notLoggedIn
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

extension Notification.Name {
    static let harnessModelsChanged = Notification.Name("harnessModelsChanged")
}

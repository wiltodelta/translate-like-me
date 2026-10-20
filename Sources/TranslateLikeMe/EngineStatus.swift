import Foundation

// Proactively checks whether the currently selected engine is ready to translate,
// so the status menu can warn about a missing CLI or a signed-out account BEFORE the
// user hits the shortcut, instead of only surfacing it as an error afterwards.
//
// The checks are cheap: a filesystem lookup for the CLI, and `claude auth status`
// / `codex login status` (each ~0.1-0.2s) / `grok models` (~0.9s). Run off the
// main thread.
enum EngineStatus {
    // The status words the menu and onboarding share.
    static var readyText: String { String(localized: "Ready", comment: "Engine or dictation status") }
    static var checkingText: String {
        String(localized: "Checking…", comment: "Engine status while it is being checked")
    }

    enum Readiness: Equatable {
        case ready
        case notInstalled
        case notLoggedIn
        case failed(String)
    }

    // The engine chosen in Settings by default; onboarding checks each one.
    static func check(provider: Provider = Settings.provider) async -> Readiness {
        guard let binary = await Translator.binaryPath(name: provider.cliBinaryName) else {
            return .notInstalled
        }
        return await readiness(binary: binary, provider: provider)
    }

    // grok keeps its default model in its own config, which the app does not
    // read; `grok models` (its sign-in probe) names it, so the probe records it
    // for Settings' "Default (…)" label and Effort picker. Off the main thread.
    static func refreshGrokDefault() async {
        guard let binary = await Translator.binaryPath(name: Provider.grok.cliBinaryName) else { return }
        _ = await readiness(binary: binary, provider: .grok)
    }

    private static func readiness(binary: String, provider: Provider) async -> Readiness {
        do {
            let result = try await ProcessRunner.run(
                binary: binary, arguments: provider.statusArguments,
                environment: Translator.toolEnvironment(adding: provider.cliEnvironment),
                deadline: ProcessRunner.deadline(after: 10))
            let output = result.stdout + result.stderr
            if provider == .grok, let model = HarnessModels.grokDefaultModel(in: output) {
                Settings.grokDefaultModel = model
            }
            return provider.isSignedIn(statusOutput: output.lowercased(), exitCode: result.status)
                ? .ready : .notLoggedIn
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

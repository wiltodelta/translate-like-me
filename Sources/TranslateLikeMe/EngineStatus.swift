import Foundation

// Proactively checks whether the currently selected engine is ready to translate,
// so the status menu can warn about a missing CLI or a signed-out account BEFORE the
// user hits the shortcut, instead of only surfacing it as an error afterwards.
//
// The checks are cheap: a filesystem lookup for the CLI, and `claude auth status`
// / `codex login status` (each ~0.1-0.2s) / `grok models` (~0.9s). Run off the
// main thread.
enum EngineStatus {
    enum Readiness: Equatable {
        case ready
        case notInstalled(cli: String)   // e.g. the `claude` / `codex` command
        case notLoggedIn(service: String) // e.g. "Claude", "ChatGPT"
        case noKey                        // API-key mode, key field empty
    }

    static func check() -> Readiness {
        let provider = Settings.provider
        switch Settings.effectiveAuthMode {
        case .apiKey:
            return Settings.apiKey(for: provider).isEmpty ? .noKey : .ready
        case .subscription:
            guard let binary = Translator.binaryPath(name: provider.cliBinaryName) else {
                return .notInstalled(cli: provider.cliBinaryName)
            }
            return isSignedIn(binary: binary, provider: provider) ? .ready
                                                                  : .notLoggedIn(service: provider.shortName)
        }
    }

    // grok keeps its default model in its own config, which the app does not
    // read; `grok models` (its sign-in probe) names it, so the probe records it
    // for Settings' "Default (…)" label and Effort picker. Off the main thread.
    static func refreshGrokDefault() {
        guard let binary = Translator.binaryPath(name: Provider.grok.cliBinaryName) else { return }
        _ = isSignedIn(binary: binary, provider: .grok)
    }

    private static func isSignedIn(binary: String, provider: Provider) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = provider.statusArguments
        process.environment = Translator.toolEnvironment(adding: provider.cliEnvironment)
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return false
        }
        // Read before waitUntilExit to avoid a full-pipe deadlock on large output.
        // Both streams are combined: codex prints its status on stderr.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = (String(data: outData, encoding: .utf8) ?? "") + (String(data: errData, encoding: .utf8) ?? "")
        if provider == .grok, let model = HarnessModels.grokDefaultModel(in: output) {
            Settings.grokDefaultModel = model
        }
        return provider.isSignedIn(statusOutput: output.lowercased(), exitCode: process.terminationStatus)
    }
}

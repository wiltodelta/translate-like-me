import Foundation

// Proactively checks whether the currently selected engine is ready to translate,
// so the panel can warn about a missing CLI or a signed-out account BEFORE the
// user hits the shortcut, instead of only surfacing it as an error afterwards.
//
// The checks are cheap: a filesystem lookup for the CLI, and `claude auth status`
// / `codex login status` (each ~0.1-0.2s). Run off the main thread.
enum EngineStatus {
    enum Readiness: Equatable {
        case ready
        case notInstalled(cli: String)   // e.g. the `claude` / `codex` command
        case notLoggedIn(service: String) // e.g. "Claude", "ChatGPT"
        case noKey                        // API-key mode, key field empty
    }

    static func check() -> Readiness {
        let provider = Settings.provider
        switch Settings.authMode {
        case .apiKey:
            return Settings.apiKey(for: provider).isEmpty ? .noKey : .ready
        case .subscription:
            let cli = provider == .anthropic ? "claude" : "codex"
            guard let binary = Translator.binaryPath(name: cli) else {
                return .notInstalled(cli: cli)
            }
            let service = provider == .anthropic ? "Claude" : "ChatGPT"
            return isSignedIn(binary: binary, provider: provider) ? .ready
                                                                  : .notLoggedIn(service: service)
        }
    }

    private static func isSignedIn(binary: String, provider: Provider) -> Bool {
        // claude: `auth status` prints JSON with "loggedIn": true on stdout.
        // codex:  `login status` prints "Logged in ..." on STDERR (stdout is empty),
        //         exit 0. So both streams are read and combined before matching.
        let args = provider == .anthropic ? ["auth", "status"] : ["login", "status"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.environment = Translator.toolEnvironment()
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
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = ((String(data: outData, encoding: .utf8) ?? "")
                    + (String(data: errData, encoding: .utf8) ?? "")).lowercased()

        switch provider {
        case .anthropic:
            return text.replacingOccurrences(of: " ", with: "").contains("\"loggedin\":true")
        case .openai:
            return process.terminationStatus == 0
                && text.contains("logged in")
                && !text.contains("not logged in")
        }
    }
}

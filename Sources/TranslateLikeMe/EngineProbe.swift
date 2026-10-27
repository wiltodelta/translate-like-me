import Foundation
import Observation

// Whether an engine actually translates, as onboarding shows it. A signed-in CLI
// is not enough: a spent limit or a broken install only shows in a real run.
enum EngineHealth: Equatable {
    case checking
    case working
    case notInstalled
    case notSignedIn
    case limitReached(String)
    case failed(String)

    // The sign-in check's verdict, nil when it passed and the test run decides.
    init?(_ readiness: EngineStatus.Readiness) {
        switch readiness {
        case .ready: return nil
        case .notInstalled: self = .notInstalled
        case .notLoggedIn: self = .notSignedIn
        case .failed(let message): self = .failed(message)
        }
    }

    // The test translation's failure.
    init(_ error: Error) {
        switch error {
        case let limit as LimitReachedError: self = .limitReached(limit.message)
        case TranslatorError.notSignedIn: self = .notSignedIn
        case TranslatorError.binaryNotFound, LocalModelError.notDownloaded: self = .notInstalled
        default: self = .failed(error.localizedDescription)
        }
    }
}

// Checks an engine the way a translation would use it: the cheap sign-in check
// first (EngineStatus), then one short real translation, so "works" means a
// translation went through, not only that a CLI is signed in.
enum EngineProbe {
    static let sample = "Hello"
    static let samplePair = LanguagePair(first: "en", second: "es", shortcut: nil)

    static func run(_ provider: Provider) async -> EngineHealth {
        let readiness = await EngineStatus.check(provider: provider)
        if let health = EngineHealth(readiness) { return health }
        let health: EngineHealth
        do {
            let response = try await Translator.translate(sample, pair: samplePair, provider: provider)
            health = translationHealth(response)
        } catch {
            health = EngineHealth(error)
        }
        // The test run loaded a local model (up to 7.5 GB); onboarding checks
        // every engine, so release it before the next engine is checked.
        if !provider.usesCLI { await LocalEngine.shared.releaseIfIdle(reason: "check") }
        return health
    }

    // A bounded smoke check, not a model quality score. Strip only punctuation:
    // an echoed greeting, an answer or a CLI notice must not count as working.
    static func translationHealth(_ response: String) -> EngineHealth {
        let greeting = response.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
        guard greeting == "hola" else {
            return .failed(String(localized: """
                The engine responded, but the test translation was incorrect. Choose another model and try again.
                """))
        }
        return .working
    }
}

// The checks onboarding shows, one per provider, each rerun on request; a newer
// run replaces an older one for the same provider.
@MainActor
@Observable
final class EngineChecks {
    private(set) var health: [Provider: EngineHealth] = [:]
    @ObservationIgnored private var runs: [Provider: Task<Void, Never>] = [:]
    @ObservationIgnored private let probe: @Sendable (Provider) async -> EngineHealth

    init(probe: @escaping @Sendable (Provider) async -> EngineHealth = { await EngineProbe.run($0) }) {
        self.probe = probe
    }

    func check(_ provider: Provider) {
        runs[provider]?.cancel()
        health[provider] = .checking
        let probe = probe
        runs[provider] = Task {
            let result = await probe(provider)
            guard !Task.isCancelled else { return }
            health[provider] = result
        }
    }

    func cancelAll() {
        runs.values.forEach { $0.cancel() }
        runs.removeAll()
        // A cancelled check must be restartable when its page is visited again.
        health = health.filter { $0.value != .checking }
    }
}

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
        }
    }

    // The test translation's failure.
    init(_ error: Error) {
        switch error {
        case let limit as LimitReachedError: self = .limitReached(limit.message)
        case TranslatorError.notSignedIn: self = .notSignedIn
        case TranslatorError.binaryNotFound: self = .notInstalled
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
        let readiness = await Task.detached { EngineStatus.check(provider: provider) }.value
        if let health = EngineHealth(readiness) { return health }
        do {
            _ = try await Translator.translate(sample, pair: samplePair, provider: provider)
            return .working
        } catch {
            return EngineHealth(error)
        }
    }
}

// The checks onboarding shows, one per provider, each rerun on request; a newer
// run replaces an older one for the same provider.
@MainActor
@Observable
final class EngineChecks {
    private(set) var health: [Provider: EngineHealth] = [:]
    @ObservationIgnored private var runs: [Provider: Task<Void, Never>] = [:]

    func check(_ provider: Provider) {
        runs[provider]?.cancel()
        health[provider] = .checking
        runs[provider] = Task {
            let result = await EngineProbe.run(provider)
            guard !Task.isCancelled else { return }
            health[provider] = result
        }
    }

    func cancelAll() {
        runs.values.forEach { $0.cancel() }
        runs.removeAll()
    }
}

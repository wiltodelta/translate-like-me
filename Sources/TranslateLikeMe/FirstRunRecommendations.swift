import Carbon
import Foundation

// A one-time seed, before the legacy migrations persist empty collections.
// Existing values, including deliberately empty collections, always win.
enum FirstRunRecommendations {
    static let marker = "didApplyFirstRunRecommendations"

    @MainActor
    static func apply(in defaults: UserDefaults = .standard, suggestions: [String]? = nil,
                      physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        guard defaults.object(forKey: marker) == nil else { return }
        let keys = ["didCompleteFirstRun", "languagePairs", "rewritePresets", "languageA", "languageB",
                    "replaceKeyCode", "replaceModifiers", "style", "provider", "localModel", "dictationModel",
                    "dictationEnabled", "dictationShortcut", "dictationMicrophone"]
            + Provider.allCases.flatMap { ["harnessModel.\($0.rawValue)", "harnessEffort.\($0.rawValue)"] }
        // Launch fixtures must never persist their argument-domain configuration.
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        guard keys.allSatisfy({ arguments[$0] == nil }) else { return }
        defer { defaults.set(true, forKey: marker) }
        guard keys.allSatisfy({ defaults.object(forKey: $0) == nil }) else { return }

        let suggestions = suggestions ?? Languages.systemSuggestions
        let pairs = suggestions.isEmpty ? [] : [Languages.newPair(after: [], suggestions: suggestions)]
        Settings.storePairs(pairs, in: defaults)
        defaults.set(localModel(physicalMemory: physicalMemory).rawValue, forKey: "localModel")
        defaults.set(dictationModel(physicalMemory: physicalMemory).rawValue, forKey: "dictationModel")
        Settings.storeRecommendedProvider(.local, in: defaults)
        let preset = RewritePreset(name: String(localized: "Improve Text"),
                                   shortcut: KeyCombo(keyCode: 38, modifiers: Int(cmdKey | optionKey)))
        defaults.set(try? JSONEncoder().encode([preset]), forKey: "rewritePresets")
    }

    // A completed translation, never merely an installed or signed-in CLI.
    // Keep a working current engine; otherwise use stable provider order after
    // all checks finish, so completion timing cannot choose the recommendation.
    static func checksComplete(_ health: [Provider: EngineHealth]) -> Bool {
        Provider.allCases.allSatisfy { health[$0] != nil && health[$0] != .checking }
    }

    static func workingEngine(current: Provider, health: [Provider: EngineHealth]) -> Provider? {
        guard checksComplete(health) else { return nil }
        if health[current] == .working { return current }
        return Provider.allCases.first { health[$0] == .working }
    }

    // Product policy prefers the lighter model through 16 GiB and the larger
    // model above that, accepting the lighter model's documented quality tradeoff.
    static func localModel(physicalMemory: UInt64) -> LocalModel {
        physicalMemory <= 16 << 30 ? .gemma4E2B : .gemma4Model12B
    }

    static func dictationModel(physicalMemory: UInt64) -> DictationModel {
        physicalMemory <= 16 << 30 ? .turbo : .qwen3ASR
    }

    // The existing quality comparison covers en/ru/de only.
    // This is download eligibility, not proof that an engine is working.
    static func localFallback(languages: [String], physicalMemory: UInt64,
                              availableStorage: Int64?, installed: Bool = false) -> LocalModel? {
        let measuredLanguages: Set<String> = ["en", "ru", "de"]
        let model = localModel(physicalMemory: physicalMemory)
        guard !installed, !languages.isEmpty, Set(languages).isSubset(of: measuredLanguages),
              model.fits(physicalMemory: physicalMemory), let availableStorage,
              availableStorage >= model.downloadBytes + LocalModelFiles.storageMargin else { return nil }
        return model
    }

    static func availableLocalFallback(languages: [String]) -> LocalModel? {
        // Application Support's model directory need not exist on a fresh Mac.
        var volume = LocalModelFiles.live.base
        while !FileManager.default.fileExists(atPath: volume.path), volume.path != "/" {
            volume.deleteLastPathComponent()
        }
        let memory = ProcessInfo.processInfo.physicalMemory
        let model = localModel(physicalMemory: memory)
        return localFallback(languages: languages, physicalMemory: memory,
                             availableStorage: try? LocalModelFiles.live.availableStorage(volume),
                             installed: LocalModelFiles.live.isInstalled(model))
    }
}

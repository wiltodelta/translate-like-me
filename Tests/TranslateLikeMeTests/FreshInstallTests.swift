import Carbon
import Foundation
import XCTest
@testable import TranslateLikeMe

// Runs only in the disposable, sandboxed host assembled by check-fresh-install.py.
// Each method gets a new process, preferences domain and home, including CLI caches.
@MainActor
final class FreshInstallTests: XCTestCase {
    override func setUp() async throws {
        guard let expected = ProcessInfo.processInfo.environment["TLM_FRESH_INSTALL_HOME"] else {
            throw XCTSkip("Run scripts/check-fresh-install.py for isolated first-run checks")
        }
        XCTAssertEqual(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath(),
                       URL(fileURLWithPath: expected).resolvingSymlinksInPath())
        XCTAssertTrue(Bundle.main.bundleIdentifier?.hasPrefix("com.wiltodelta.tlm-fresh-install.") == true)
        XCTAssertFalse(Settings.didCompleteFirstRun)
        XCTAssertFalse(Settings.dictationEnabled)
        XCTAssertTrue(Settings.languagePairs.isEmpty)
        XCTAssertTrue(Settings.rewritePresets.isEmpty)
        // Check the boundary with a synthetic host file, never with real credentials.
        let canary = try XCTUnwrap(ProcessInfo.processInfo.environment["TLM_FRESH_INSTALL_CANARY"])
        XCTAssertThrowsError(try Data(contentsOf: URL(fileURLWithPath: canary)))
        let endpoint = try XCTUnwrap(ProcessInfo.processInfo.environment["TLM_FRESH_INSTALL_ENDPOINT"])
        let network = try await ProcessRunner.run(binary: "/usr/bin/curl",
                                                  arguments: ["--noproxy", "*", "--max-time", "2", endpoint],
                                                  environment: Translator.toolEnvironment(),
                                                  deadline: ProcessRunner.deadline(after: 5))
        XCTAssertNotEqual(network.status, 0, "The reachable parent HTTP fixture must be blocked")
    }

    func testFreshSettingsAndMissingTools() async throws {
        Settings.persistLanguagePairs()
        Settings.moveStyleIntoPairs()
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let stored = UserDefaults.standard.persistentDomain(forName: domain)
        XCTAssertNotNil(stored?["languagePairs"], "Writes must belong to the disposable host")
        XCTAssertEqual(Settings.dictationModel, .turbo)
        XCTAssertEqual(Settings.dictationShortcut, KeyCombo(keyCode: 61, modifiers: Int(optionKey)))
        for provider in Provider.allCases where provider.usesCLI {
            let readiness = await EngineStatus.check(provider: provider)
            XCTAssertEqual(readiness, .notInstalled)
            let health = await EngineProbe.run(provider)
            XCTAssertEqual(health, .notInstalled)
            do {
                _ = try await Translator.translate("Hello", pair: EngineProbe.samplePair, provider: provider)
                XCTFail("A missing CLI must never silently succeed")
            } catch TranslatorError.binaryNotFound(let name) {
                XCTAssertEqual(name, provider.cliBinaryName)
            }
            XCTAssertNil(HarnessDefaults.configured(for: provider).model)
        }
        // A fresh install has no local model and never loads or downloads one.
        let localReadiness = await EngineStatus.check(provider: .local)
        XCTAssertEqual(localReadiness, .notInstalled)
        let localHealth = await EngineProbe.run(.local)
        XCTAssertEqual(localHealth, .notInstalled)
        do {
            _ = try await Translator.translate("Hello", pair: EngineProbe.samplePair, provider: .local)
            XCTFail("A missing local model must never silently succeed")
        } catch LocalModelError.notDownloaded(let model) {
            XCTAssertEqual(model, .translateGemma12B)
        }
    }

    func testRecommendedConfigurationAndExplicitEngineChoiceThroughStore() async throws {
        FirstRunRecommendations.apply(suggestions: ["en", "de"])
        Settings.persistLanguagePairs()
        let store = SettingsStore(refreshCatalog: { _ in })
        XCTAssertEqual(store.pairs.map(\.second), ["de"])
        XCTAssertEqual(store.rewritePresets.count, 1)
        XCTAssertFalse(Settings.dictationEnabled)
        var health = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, EngineHealth.notInstalled) })
        health[.openai] = .checking
        store.recommendWorkingEngine(health: health)
        XCTAssertFalse(store.didCheckInitialEngines)
        health[.openai] = .working
        store.recommendWorkingEngine(health: health)
        XCTAssertTrue(store.didCheckInitialEngines)
        XCTAssertEqual(Settings.provider, .openai)
        XCTAssertTrue(Settings.canRecommendProvider())
        // A real manual assignment, even to the same selected engine, wins.
        store.provider = .openai
        health[.openai] = .limitReached("Synthetic limit")
        health[.grok] = .working
        store.recommendWorkingEngine(health: health)
        XCTAssertEqual(Settings.provider, .openai)
        let original = store.rewritePresets
        FirstRunRecommendations.apply(suggestions: ["ru", "en"])
        XCTAssertEqual(Settings.rewritePresets, original)
        XCTAssertEqual(Settings.languagePairs.map(\.second), ["de"])
    }

    func testSignedOutTools() async throws {
        for provider in Provider.allCases where provider.usesCLI {
            try installTool(provider, signedIn: false)
            let readiness = await EngineStatus.check(provider: provider)
            XCTAssertEqual(readiness, .notLoggedIn)
            let health = await EngineProbe.run(provider)
            XCTAssertEqual(health, .notSignedIn)
        }
    }

    func testSyntheticTranslationThroughRealSubprocesses() async throws {
        for provider in Provider.allCases where provider.usesCLI {
            try installTool(provider, signedIn: true)
            let health = await EngineProbe.run(provider)
            XCTAssertEqual(health, .working)
            let result = try await Translator.translate("Hello", pair: EngineProbe.samplePair, provider: provider)
            XCTAssertEqual(result, "Hola")
        }
    }

    func testEmptyModelCacheFailsWithoutDownloading() async throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("models")
        let engine = DictationEngine(directory: directory, availableStorage: { _ in 20_000_000_000 })
        do {
            try await engine.prepare(download: false) { _ in }
            XCTFail("An empty cache must not report a ready model")
        } catch DictationError.notReady {}
        let loadedModel = await engine.loadedModel
        XCTAssertNil(loadedModel)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testMicrophoneDenialThenRetryAndKeyRelease() async {
        let engine = FreshInstallEngine()
        let recorder = FreshInstallRecorder()
        let controller = DictationController(enabled: true, engine: engine, recorder: recorder,
                                            interaction: .init(endCapture: {}, showError: { _ in },
                                                               showResult: { _ in }), saveModel: { _ in })
        defer { controller.cancel(restartPreparation: false) }
        controller.restore()
        await controller.operation?.value
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertTrue(controller.error?.contains("Microphone access is off") == true)
        XCTAssertEqual(engine.preparations, 0)
        XCTAssertEqual(recorder.starts, 0)
        recorder.permitted = true
        controller.prepare()
        await controller.operation?.value
        XCTAssertEqual(controller.phase, .ready)
        var key = OptionKeyGesture(keyCode: 61, initialFlags: [])
        XCTAssertEqual(key.flagsChanged(keyCode: 61, flags: .option), .press)
        controller.shortcutPressed()
        XCTAssertEqual(recorder.starts, 1)
        XCTAssertNil(key.flagsChanged(keyCode: 61, flags: .option))
        XCTAssertNil(key.flagsChanged(keyCode: 61, flags: .option))
        XCTAssertEqual(key.flagsChanged(keyCode: 61, flags: []), .release)
        controller.shortcutReleased()
        XCTAssertEqual(recorder.stops, 1)
        XCTAssertEqual(controller.phase, .recognizing)
        await controller.operation?.value
        XCTAssertEqual(engine.transcriptions, 1)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertFalse(TranslationActivity.shared.isBusy)
    }

    func testCancellationAndEmptyRecognitionHaveDistinctInternalPaths() async {
        for cancel in [true, false] {
            let engine = FreshInstallEngine()
            let recorder = FreshInstallRecorder()
            recorder.permitted = true
            var hidden = 0
            var shown: [String] = []
            let controller = DictationController(enabled: true, engine: engine, recorder: recorder,
                interaction: .init(endCapture: { hidden += 1 },
                                   showError: { _ in XCTFail("Neither path should invent a capture error") },
                                   showResult: { shown.append($0) }), saveModel: { _ in })
            controller.restore()
            await controller.operation?.value
            let before = hidden
            var key = OptionKeyGesture(keyCode: 61)
            XCTAssertEqual(key.flagsChanged(keyCode: 61, flags: .option), .press)
            controller.shortcutPressed()
            XCTAssertEqual(recorder.starts, 1)
            if cancel {
                XCTAssertEqual(key.cancel(), .cancel)
                controller.shortcutCancelled()
                XCTAssertNil(key.flagsChanged(keyCode: 61, flags: []))
                XCTAssertNil(controller.operation)
            } else {
                XCTAssertEqual(key.flagsChanged(keyCode: 61, flags: []), .release)
                controller.shortcutReleased()
                XCTAssertEqual(controller.phase, .recognizing)
            }
            await controller.operation?.value
            XCTAssertEqual(engine.transcriptions, cancel ? 0 : 1)
            XCTAssertEqual(recorder.stops, cancel ? 0 : 1)
            XCTAssertEqual(hidden, before + 1)
            XCTAssertEqual(controller.phase, .ready)
            XCTAssertNil(controller.error)
            XCTAssertNil(controller.lastResult)
            XCTAssertTrue(shown.isEmpty)
            XCTAssertFalse(TranslationActivity.shared.isBusy)
        }
    }

    private func installTool(_ provider: Provider, signedIn: Bool) throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tool = directory.appendingPathComponent(provider.cliBinaryName)
        let status: String
        switch provider {
        case .anthropic: status = signedIn ? "{\"loggedIn\":true}" : "{\"loggedIn\":false}"
        case .openai: status = signedIn ? "Logged in using ChatGPT" : "Not logged in"
        case .grok: status = signedIn ? "You are logged in with grok.com." : "You are not authenticated."
        case .antigravity: status = signedIn ? "synthetic-model\tSynthetic Model" : "Error: Please sign in."
        case .local: throw XCTSkip("The local engine has no command-line tool")
        }
        // Synthetic tools test invocation and output handling, never vendor availability.
        let response = provider == .antigravity
            ? #"{"event":"result","result":{"status":"SUCCESS","response":"Hola"}}"# : "Hola"
        let script = """
        #!/bin/sh
        if [ "$1" = auth ] || [ "$1" = login ] || [ "$1" = models ]; then
            printf '%s\\n' '\(status)'
            exit \(signedIn || provider == .grok ? 0 : 1)
        fi
        cat >/dev/null
        if [ "$1" = exec ]; then
            while [ "$#" -gt 0 ]; do
                if [ "$1" = -o ]; then shift; printf 'Hola\\n' > "$1"; exit 0; fi
                shift
            done
            exit 2
        fi
        printf '%s\\n' '\(response)'
        """
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
    }
}

@MainActor
private final class FreshInstallEngine: DictationRecognizing {
    var preparations = 0
    var transcriptions = 0
    func prepare(model: DictationModel, download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        preparations += 1
    }
    func transcribe(_ audio: URL) async throws -> String { transcriptions += 1; return "" }
    func unload() async {}
}

@MainActor
private final class FreshInstallRecorder: DictationRecording {
    var onEnd: ((Bool) -> Void)?
    let level = 0.0
    let isDeliveringAudio = true
    var permitted = false
    var starts = 0
    var stops = 0
    func requestPermission() async -> Bool { permitted }
    func useInput(_ uid: String?) {}
    func warmUp(rebuild: Bool) {}
    func coolDown() {}
    func start() throws { starts += 1 }
    func stop() throws -> Task<URL, Error> {
        stops += 1
        return Task { URL(fileURLWithPath: "/synthetic.wav") }
    }
    func discard() {}
    func shutdown() {}
}

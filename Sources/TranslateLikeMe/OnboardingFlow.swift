import AppKit
import ApplicationServices
import AVFoundation
import Observation

// The actual first-run state machine. Closing or pausing never completes setup.
@MainActor
@Observable
final class OnboardingFlow {
    enum Step { case preparation, permissions, usage }
    enum Preparation: Equatable {
        case waiting, working(Double), ready, failed
    }

    struct Effects {
        var speech: @MainActor (@escaping @Sendable (Double) -> Void) async throws -> Void
        var translation: @MainActor () async throws -> Void
        var translationState: @MainActor () -> LocalModelDownloads.State
        var cancelDownload: @MainActor () -> Void
        var microphoneGranted: @MainActor () -> Bool
        var microphoneNeedsSettings: @MainActor () -> Bool = { false }
        var accessibilityGranted: @MainActor () -> Bool
        var requestMicrophone: @MainActor () async -> Bool
        var openMicrophoneSettings: @MainActor () -> Void
        var openAccessibilitySettings: @MainActor () -> Void
        var activateDictation: @MainActor () async throws -> Void
        var complete: @MainActor () -> Void
    }

    private(set) var step: Step = .preparation
    private(set) var speech: Preparation = .waiting
    private(set) var translation: Preparation = .waiting
    private(set) var microphone = false
    private(set) var accessibility = false
    private(set) var microphoneDenied = false
    private(set) var error: String?
    private(set) var running = false
    @ObservationIgnored private let effects: Effects
    @ObservationIgnored private(set) var operation: Task<Void, Never>?

    init(effects: Effects) { self.effects = effects }

    var modelsReady: Bool { speech == .ready && translation == .ready }
    var permissionsReady: Bool { microphone && accessibility }
    var localDownloadState: LocalModelDownloads.State { effects.translationState() }

    func prepare() {
        guard operation == nil, step == .preparation else { return }
        running = true
        error = nil
        operation = Task { [self] in
            defer { running = false; operation = nil }
            do { try await prepareModels() } catch { preparationFailed(error) }
        }
    }

    private func prepareModels() async throws {
        if speech != .ready {
            speech = .working(0)
            try await effects.speech { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.running, case .working = self.speech else { return }
                    self.speech = .working(progress)
                }
            }
            try Task.checkCancellation()
            speech = .ready
        }
        if translation != .ready {
            translation = .working(0)
            try await effects.translation()
            try Task.checkCancellation()
            translation = .ready
        }
    }

    private func preparationFailed(_ failure: Error) {
        if failure is CancellationError || Task.isCancelled {
            if speech != .ready { speech = .waiting }
            if translation != .ready { translation = .waiting }
            return
        }
        error = failure.localizedDescription
        if speech != .ready {
            speech = .failed
        } else {
            translation = .failed
        }
    }

    func pause() {
        guard operation != nil else { return }
        operation?.cancel()
        if case .working = translation { effects.cancelDownload() }
    }

    func continueFromPreparation() {
        guard modelsReady, !running else { return }
        refreshPermissions()
        step = .permissions
    }

    func refreshPermissions() {
        microphone = effects.microphoneGranted()
        accessibility = effects.accessibilityGranted()
        if microphone {
            microphoneDenied = false
        } else if effects.microphoneNeedsSettings() {
            microphoneDenied = true
        }
        if step == .usage && !permissionsReady { step = .permissions }
    }

    func permissionAction() {
        guard step == .permissions, modelsReady, operation == nil else { return }
        refreshPermissions()
        if !microphone && microphoneDenied { effects.openMicrophoneSettings(); return }
        if microphone && !accessibility { effects.openAccessibilitySettings(); return }
        running = true
        error = nil
        operation = Task {
            defer { running = false; operation = nil }
            if !microphone {
                microphone = await effects.requestMicrophone()
                microphoneDenied = !microphone
                return
            }
            guard permissionsReady else { return }
            do {
                try await effects.activateDictation()
                try Task.checkCancellation()
                refreshPermissions()
                if permissionsReady { step = .usage }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    @discardableResult
    func finish() -> Bool {
        refreshPermissions()
        guard step == .usage, modelsReady, permissionsReady, !running else { return false }
        effects.complete()
        return true
    }

    // Changes in Settings invalidate the prepared configuration, never the user's choice.
    func configurationChanged() {
        pause()
        speech = .waiting
        translation = .waiting
        error = nil
        step = .preparation
    }
}

@MainActor
extension OnboardingFlow.Effects {
    static func live(store: SettingsStore) -> Self {
        let downloads = LocalModelDownloads.shared
        return Self(speech: { progress in
            let engine = DictationEngine()
            do {
                try await engine.prepare(model: Settings.dictationModel, download: true, progress: progress)
                await engine.unload()
            } catch {
                await engine.unload()
                throw error
            }
        }, translation: {
            try await downloads.downloadAndWait(store.localModel)
            try await checkEngine(.local)
            if store.provider != .local { try await checkEngine(store.provider) }
        }, translationState: { downloads.state(of: store.localModel) },
             cancelDownload: { downloads.cancel() },
             microphoneGranted: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
             microphoneNeedsSettings: {
                 let status = AVCaptureDevice.authorizationStatus(for: .audio)
                 return status == .denied || status == .restricted
             },
             accessibilityGranted: { AXIsProcessTrusted() },
             requestMicrophone: { await DictationRecorder().requestPermission() },
             openMicrophoneSettings: { openPrivacy("Microphone") },
             openAccessibilitySettings: {
                 SelectionService.promptForAccessibility()
                 openPrivacy("Accessibility")
             },
             activateDictation: {
                 let dictation = DictationController.shared
                 guard DictationMicrophone.resolve(dictation.microphone?.uid) != nil else {
                     throw DictationError.microphone
                 }
                 dictation.setEnabled(true)
                 if dictation.phase != .ready { dictation.prepare() }
                 await dictation.operation?.value
                 guard dictation.phase == .ready else {
                     throw OnboardingFailure(message: dictation.error ?? String(localized: "Dictation is not ready."))
                 }
             }, complete: {
                 Settings.didCompleteFirstRun = true
                 LocalPreparation.refreshSelected()
             })
    }

    private static func checkEngine(_ provider: Provider) async throws {
        switch await EngineProbe.run(provider) {
        case .working: return
        case .failed(let message), .limitReached(let message): throw OnboardingFailure(message: message)
        case .notInstalled: throw OnboardingFailure(message: provider.notInstalledHint)
        case .notSignedIn: throw OnboardingFailure(message: provider.notSignedInHint)
        case .checking:
            throw OnboardingFailure(message: String(localized: "The local translation test failed. Try Again."))
        }
    }

    private static func openPrivacy(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

struct OnboardingFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension OnboardingFlow {
    // Dev-only fixtures render the shipping views without downloads, TCC or preferences.
    static func preview(stage: String) -> OnboardingFlow {
        var mic = stage == "accessibility" || stage == "permissions-ready" || stage == "usage"
        var trusted = stage == "permissions-ready" || stage == "usage"
        let flow = OnboardingFlow(effects: Effects(speech: { progress in progress(1) }, translation: {},
            translationState: { .downloading(0.3) }, cancelDownload: {},
            microphoneGranted: { mic }, accessibilityGranted: { trusted },
            requestMicrophone: { mic = true; return true },
            openMicrophoneSettings: {}, openAccessibilitySettings: { trusted = true },
            activateDictation: {}, complete: {}))
        switch stage {
        case "downloading":
            flow.speech = .ready
            flow.translation = .working(0)
            flow.running = true
        case "failed":
            flow.speech = .ready
            flow.translation = .failed
            flow.error = LocalModelError.insufficientStorage(10_000_000_000).localizedDescription
        case "permissions", "accessibility", "permissions-ready", "usage":
            flow.speech = .ready
            flow.translation = .ready
            flow.step = stage == "usage" ? .usage : .permissions
            flow.refreshPermissions()
        default: break
        }
        return flow
    }
}

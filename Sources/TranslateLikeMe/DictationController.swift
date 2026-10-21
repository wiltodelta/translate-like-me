import AppKit
import Observation
import os

private let dictationLog = Logger.app("dictation")

@MainActor
struct DictationInteraction {
    var endCapture: () -> Void
    var showError: (String) -> Void
    var showResult: (String) -> Void
    var showCapture: () -> Void = {}
    // Returns whether the text reached the focused app; nil never pastes (tests).
    // Main actor: the Paste key lookup reads Text Input Sources, which trap elsewhere.
    var deliver: (@MainActor (String) async throws -> Bool)?

    static let live = DictationInteraction(endCapture: { DictationIndicator.shared.hide() },
       showError: { PopupController.shared.showError($0) },
       showResult: { PopupController.shared.showResult($0, kind: .dictation) },
       showCapture: { DictationIndicator.shared.show() },
       deliver: { try await deliverAtFocus($0) })

    private static func deliverAtFocus(_ text: String) async throws -> Bool {
        try await PasteDelivery(access: LiveDictationAccess(pasteKey: KeyboardLayout.pasteKey)).insert(text)
    }
}

@MainActor
@Observable
final class DictationController {
    static let shared = DictationController()
    private(set) var enabled: Bool
    private(set) var model: DictationModel
    private(set) var session = DictationSession()
    private(set) var progress: Double = 0
    private(set) var level: Double = 0
    private(set) var error: String?
    var lastResult: String? { results[.dictation] }

    @ObservationIgnored private let results: LastResults

    @ObservationIgnored private let engine: any DictationRecognizing
    @ObservationIgnored private let recorder: any DictationRecording
    @ObservationIgnored private let interaction: DictationInteraction
    @ObservationIgnored private let saveModel: (DictationModel) -> Void
    @ObservationIgnored private(set) var operation: Task<Void, Never>?
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var modelRelease: Task<Void, Never>?
    @ObservationIgnored private var releaseOnCompletion = false
    @ObservationIgnored private var meter: Timer?
    @ObservationIgnored private(set) var tail: Task<Void, Never>?
    @ObservationIgnored private let releaseTail: Duration
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var ownsActivity = false
    @ObservationIgnored private var prepareAfterOperation = false

    init(enabled: Bool, model: DictationModel = .turbo,
         engine: any DictationRecognizing, recorder: any DictationRecording,
         interaction: DictationInteraction, results: LastResults = LastResults(),
         releaseTail: Duration = .zero,
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         saveModel: @escaping (DictationModel) -> Void = { Settings.dictationModel = $0 }) {
        self.enabled = enabled
        self.model = model
        self.engine = engine
        self.recorder = recorder
        self.interaction = interaction
        self.results = results
        self.releaseTail = releaseTail
        self.sleep = sleep
        self.saveModel = saveModel
    }

    private convenience init() {
        self.init(enabled: Settings.dictationEnabled, model: Settings.dictationModel,
                  engine: DictationEngine(), recorder: DictationRecorder(),
                  interaction: .live, results: .shared, releaseTail: Self.liveReleaseTail)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.releaseForMemoryPressure()
            }
        }
        pressureSource = source
        source.resume()
    }

    // Speakers often finish their last word just after letting go of the key.
    static let liveReleaseTail = Duration.seconds(1)

    var phase: DictationSession.Phase { session.phase }
    var isActive: Bool { [.starting, .recording, .recognizing, .cancelling].contains(phase) }

    func releaseForMemoryPressure() {
        releaseOnCompletion = true
        if operation == nil && !ownsActivity { releaseModelIfNeeded() }
    }

    func restore() { if enabled { prepare() } }

    // Sleep can leave the prepared input bound to a stale device.
    func systemDidWake() { if enabled { recorder.warmUp(rebuild: true) } }

    func selectModel(_ model: DictationModel) {
        guard self.model != model, !isActive else { return }
        self.model = model
        saveModel(model)
        error = nil
        progress = 0
        if operation != nil {
            cancel(restartPreparation: false)
            prepareAfterOperation = enabled
        } else if enabled {
            prepare()
        }
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        Settings.dictationEnabled = value
        if value {
            Settings.dictationShortcut = Settings.dictationShortcut
            if operation == nil { prepare() } else { prepareAfterOperation = true }
        } else {
            prepareAfterOperation = false
            cancel()
            recorder.coolDown()
        }
        HotKeyManager.shared.reload()
    }

    func prepare() {
        guard enabled, operation == nil else { return }
        error = nil
        progress = 0
        let id = session.begin(.preparing)
        operation = Task { [self] in
            defer { complete(id) }
            guard await recorder.requestPermission() else {
                fail(String(localized: """
                    Microphone access is off. Allow Translate Like Me in System Settings > Privacy & Security > \
                    Microphone.
                    """), id: id)
                return
            }
            recorder.warmUp(rebuild: false)
            do {
                try await prepareEngine(id)
                guard session.accepts(id, in: .preparing), !Task.isCancelled else { return }
                session.transition(.ready, for: id)
                dictationLog.notice("Dictation model ready")
            } catch { handle(error, id: id) }
        }
    }

    func shortcutPressed() {
        guard enabled, phase == .ready, operation == nil, !TranslationActivity.shared.isBusy else {
            dictationLog.notice("""
                Dictation press ignored: enabled \(self.enabled), phase \
                \(String(describing: self.phase), privacy: .public), \
                operation \(self.operation != nil), busy \(TranslationActivity.shared.isBusy)
                """)
            return
        }
        dictationLog.notice("Dictation hold pressed")
        startCapture()
    }

    func shortcutReleased() {
        dictationLog.notice("Dictation hold released, phase \(String(describing: self.phase), privacy: .public)")
        switch session.releaseAction() {
        case .stop: finishAfterTail()
        case .ignore: break
        }
    }

    // Keep recording briefly after release, then stop as an immediate release would.
    private func finishAfterTail() {
        guard releaseTail > .zero else { return stop() }
        guard tail == nil else { return }
        let id = session.id
        tail = Task { [self] in
            try? await sleep(releaseTail)
            guard !Task.isCancelled, session.id == id else { return }
            stop()
        }
    }

    func shortcutCancelled() {
        dictationLog.notice("Dictation hold cancelled, phase \(String(describing: self.phase), privacy: .public)")
        if phase == .starting || phase == .recording { cancel() }
    }

    private func startCapture() {
        ownsActivity = true
        TranslationActivity.shared.isBusy = true
        let id = session.begin(.starting)
        do {
            // Hardware starts on the capture queue.
            try recorder.start()
            recorder.onEnd = { [weak self] success in
                guard let self, self.session.id == id else { return }
                if success {
                    self.stop()
                } else {
                    self.fail(String(localized: """
                        Recording stopped unexpectedly. Check your microphone, then try again.
                        """), id: id)
                    self.endCapture()
                }
            }
            let started = ContinuousClock.now
            meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.session.id == id,
                          [.starting, .recording].contains(self.phase) else { return }
                    self.level = self.recorder.level
                    guard self.phase == .starting else { return }
                    // Listening appears only once the microphone delivers audio.
                    if self.recorder.isDeliveringAudio {
                        self.session.transition(.recording, for: id)
                        self.interaction.showCapture()
                    } else if started.duration(to: .now) > .seconds(3) {
                        self.fail(DictationError.microphone.localizedDescription, id: id)
                        self.endCapture()
                    }
                }
            }
        } catch {
            handle(error, id: id)
            endCapture()
        }
    }

    func stop() {
        guard phase == .recording || phase == .starting, operation == nil else { return }
        meter?.invalidate()
        meter = nil
        let id = session.id
        do {
            let drain = try recorder.stop()
            session.transition(.recognizing, for: id)
            operation = Task { [self] in
                defer { complete(id) }
                do {
                    let audio = try await drain.value
                    try Task.checkCancellation()
                    dictationLog.notice("Dictation recording drained; recognition queued")
                    try await prepareEngine(id, download: false)
                    guard session.accepts(id, in: .recognizing), !Task.isCancelled else { return }
                    dictationLog.notice("Dictation recognition started")
                    let text = try await engine.transcribe(audio)
                    dictationLog.notice("Dictation recognition finished, empty \(text.isEmpty)")
                    guard session.accepts(id, in: .recognizing), !Task.isCancelled else { return }
                    guard !text.isEmpty else {
                        session.transition(.ready, for: id)
                        return
                    }
                    results.record(text, kind: .dictation)
                    let delivered = try await interaction.deliver?(text) ?? false
                    guard session.accepts(id, in: .recognizing), !Task.isCancelled else { return }
                    if !delivered { interaction.showResult(text) }
                    session.transition(.ready, for: id)
                } catch { handle(error, id: id) }
            }
        } catch {
            handle(error, id: id)
            endCapture()
        }
    }

    func shutdown() {
        cancel(restartPreparation: false)
        recorder.shutdown()
    }

    func cancel(restartPreparation: Bool = true) {
        if !restartPreparation { prepareAfterOperation = false }
        if restartPreparation && enabled && phase == .preparing { prepareAfterOperation = true }
        operation?.cancel()
        _ = session.begin(enabled && operation != nil ? .cancelling : enabled ? .ready : .disabled)
        endCapture()
        if operation == nil { releaseModelIfNeeded() }
    }

    private func prepareEngine(_ id: UUID, download: Bool = true) async throws {
        // An earlier pressure notification may have queued a release before this
        // recording began. Finish it before taking a model for the new session.
        await modelRelease?.value
        modelRelease = nil
        try Task.checkCancellation()
        try await engine.prepare(model: model, download: download) { [weak self] value in
            Task { @MainActor in
                guard let self, self.session.id == id else { return }
                self.progress = value
            }
        }
        try Task.checkCancellation()
    }

    private func handle(_ failure: Error, id: UUID) {
        guard session.id == id else { return }
        if failure is CancellationError {
            session.transition(enabled ? .ready : .disabled, for: id)
        } else {
            let kind = String(describing: type(of: failure))
            dictationLog.error("Dictation failed (\(kind, privacy: .public))")
            let message = switch failure {
            case DictationError.microphone, DictationError.insufficientStorage, DictationError.recognitionLimit:
                failure.localizedDescription
            case _ where phase == .preparing:
                String(localized: "Dictation couldn't be prepared. Check your connection, then choose Try Again.")
            default:
                String(localized: """
                    Speech couldn't be recognized. Try dictating again, or prepare dictation again in Settings.
                    """)
            }
            fail(message, id: id)
        }
    }

    private func fail(_ message: String, id: UUID) {
        guard session.transition(.failed, for: id) else { return }
        dictationLog.notice("Dictation entered failed state")
        error = message
        if ownsActivity { interaction.showError(message) }
    }

    private func complete(_ id: UUID) {
        operation = nil
        endCapture()
        if prepareAfterOperation && enabled {
            prepareAfterOperation = false
            prepare()
            return
        }
        if session.id != id { _ = session.begin(enabled ? .ready : .disabled) }
        releaseModelIfNeeded()
    }

    private func endCapture() {
        tail?.cancel()
        tail = nil
        meter?.invalidate()
        meter = nil
        recorder.discard()
        level = 0
        if ownsActivity { TranslationActivity.shared.isBusy = false }
        ownsActivity = false
        interaction.endCapture()
    }

    private func releaseModelIfNeeded() {
        guard !enabled || releaseOnCompletion else { return }
        releaseOnCompletion = false
        guard modelRelease == nil else { return }
        let engine = engine
        modelRelease = Task { await engine.unload() }
    }
}

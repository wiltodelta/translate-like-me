import AppKit
import Observation
import os

private let dictationLog = Logger.app("dictation")

@MainActor
struct DictationInteraction {
    var beginCapture: (SelectionActivity) -> (SelectionTarget?, () -> Void)
    var endCapture: () -> Void
    var showError: (String) -> Void
    var showResult: (String) -> Void

    static let live = DictationInteraction(beginCapture: { activity in
        let application = NSWorkspace.shared.frontmostApplication
        let target = application.flatMap {
            SelectionTarget.capture(pid: $0.processIdentifier, allowingCaret: true)
        }
        let pid = application?.processIdentifier ?? -1
        if target == nil {
            dictationLog.notice("Dictation has no supported AX target, original pid \(pid)")
        } else if target?.isWindowOnly == true {
            dictationLog.notice("Dictation captured a window target, original pid \(pid)")
        }
        let stop = activity.monitor()
        DictationIndicator.shared.show()
        return (target, stop)
    }, endCapture: { DictationIndicator.shared.hide() },
       showError: { PopupController.shared.showError($0) },
       showResult: { PopupController.shared.showResult($0, kind: .dictation, copied: false) })
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
    private(set) var lastResult: String?

    @ObservationIgnored private let engine: any DictationRecognizing
    @ObservationIgnored private let recorder: any DictationRecording
    @ObservationIgnored private let interaction: DictationInteraction
    @ObservationIgnored private let saveModel: (DictationModel) -> Void
    @ObservationIgnored private(set) var operation: Task<Void, Never>?
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var modelRelease: Task<Void, Never>?
    @ObservationIgnored private var releaseOnCompletion = false
    @ObservationIgnored private var meter: Timer?
    @ObservationIgnored private var target: SelectionTarget?
    @ObservationIgnored private var activity: SelectionActivity?
    @ObservationIgnored private var stopMonitoring: (() -> Void)?
    @ObservationIgnored private var ownsActivity = false
    @ObservationIgnored private var prepareAfterOperation = false

    init(enabled: Bool, model: DictationModel = .turbo,
         engine: any DictationRecognizing, recorder: any DictationRecording,
         interaction: DictationInteraction,
         saveModel: @escaping (DictationModel) -> Void = { Settings.dictationModel = $0 }) {
        self.enabled = enabled
        self.model = model
        self.engine = engine
        self.recorder = recorder
        self.interaction = interaction
        self.saveModel = saveModel
    }

    private convenience init() {
        self.init(enabled: Settings.dictationEnabled, model: Settings.dictationModel,
                  engine: DictationEngine(), recorder: DictationRecorder(),
                  interaction: .live)
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

    var phase: DictationSession.Phase { session.phase }
    var isActive: Bool { [.starting, .recording, .recognizing, .cancelling].contains(phase) }

    func releaseForMemoryPressure() {
        releaseOnCompletion = true
        if operation == nil && !ownsActivity { releaseModelIfNeeded() }
    }

    func restore() { if enabled { prepare() } }

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
        case .stop: stop()
        case .ignore: break
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
        let activity = SelectionActivity()
        self.activity = activity
        do {
            // AX reads can block on the other app. Start collecting audio before
            // inspecting its insertion target or constructing the indicator.
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
            (target, stopMonitoring) = interaction.beginCapture(activity)
            let started = ContinuousClock.now
            meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.session.id == id,
                          [.starting, .recording].contains(self.phase) else { return }
                    self.level = self.recorder.level
                    guard self.phase == .starting else { return }
                    if self.recorder.isDeliveringAudio {
                        self.session.transition(.recording, for: id)
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
            let audio = try recorder.stop()
            dictationLog.notice("Dictation recording drained; recognition queued")
            session.transition(.recognizing, for: id)
            operation = Task { [self] in
                defer { complete(id) }
                do {
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
                    lastResult = text
                    let access = LiveSelectionAccess(pid: target?.pid ?? 0,
                                                     activity: activity ?? SelectionActivity())
                    let delivery = DictationDelivery(access: access,
                                                     requiresTextConfirmation: target?.isWindowOnly != true)
                    let outcome = try await delivery.insert(text, into: target)
                    guard session.accepts(id, in: .recognizing), !Task.isCancelled else { return }
                    if outcome == .retained { interaction.showResult(text) }
                    session.transition(.ready, for: id)
                } catch { handle(error, id: id) }
            }
        } catch {
            handle(error, id: id)
            endCapture()
        }
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
            case DictationError.microphone, DictationError.voiceProcessing, DictationError.insufficientStorage:
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
        meter?.invalidate()
        meter = nil
        recorder.discard()
        stopMonitoring?()
        stopMonitoring = nil
        activity = nil
        target = nil
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

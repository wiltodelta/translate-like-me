import AppKit
import os

private let log = Logger.app("translation")

// Whether a translation is currently in flight. The status item swaps its icon
// between the idle plate and the busy glyph in response to `.translationActivityChanged`.
@MainActor
final class TranslationActivity {
    static let shared = TranslationActivity()
    private init() {}
    var isBusy = false {
        didSet {
            guard oldValue != isBusy else { return }
            NotificationCenter.default.post(name: .translationActivityChanged, object: nil)
        }
    }
}

typealias SelectionTransform = @Sendable (String) async throws -> String

@MainActor
struct TranslationInteraction {
    var showProgress: (PopupController.ResultKind, @escaping () -> Void) -> Void
    var hideProgress: () -> Void
    var showError: (String) -> Void
    var showLimit: (String) -> Void
    var showResult: (String, PopupController.ResultKind) -> Void
    var run: @MainActor (PopupController.ResultKind, SelectionTransform) async throws -> SelectionOutcome

    static let live = TranslationInteraction(
        showProgress: { ActivityIndicator.translation.show(kind: $0, cancel: $1) },
        hideProgress: { ActivityIndicator.translation.hide() },
        showError: { PopupController.shared.showError($0) },
        showLimit: { PopupController.shared.showLimitReached($0) },
        showResult: { PopupController.shared.showResult($0, kind: $1) },
        run: { try await runSelection(kind: $0, transform: $1) })

    private static func runSelection(kind: PopupController.ResultKind,
                                     transform: SelectionTransform) async throws -> SelectionOutcome {
        // Text Input Sources and the event monitors belong on the main thread.
        let copyKey = KeyboardLayout.copyKey
        let pasteKey = KeyboardLayout.pasteKey
        let activity = SelectionActivity()
        let stopMonitoring = activity.monitor()
        defer { stopMonitoring() }
        // AX can wait on another process. Cancellation here must never send Copy.
        let pid = await Task.detached(priority: .userInitiated) { SelectionTarget.focusedPID ?? 0 }.value
        try Task.checkCancellation()
        let focusedApp = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
        log.notice("Selection focused app: \(focusedApp, privacy: .public)")
        return try await SelectionWorkflow(
            access: LiveSelectionAccess(pid: pid, activity: activity, copyKey: copyKey, pasteKey: pasteKey),
            didProduceResult: { await LastResults.shared.record($0, kind: kind) }
        ).run(transform: transform)
    }
}

// Drives the translate and rewrite flows: copy the selection, run it through the
// engine, paste the result back in place. Errors surface in a small cursor-anchored popup.
//
// The shared paste receipt controls when the clipboard can be restored
// (SelectionWorkflow); an undelivered result remains available in the popup.
@MainActor
final class TranslationController {
    static let shared = TranslationController()

    private let interaction: TranslationInteraction
    private(set) var operation: Task<Void, Never>?

    init(interaction: TranslationInteraction = .live) { self.interaction = interaction }

    func cancel() { operation?.cancel() }

    // Translates the selection with `pair` (each pair has its own shortcut).
    func run(pair: LanguagePair) {
        guard pair.isComplete else {
            interaction.showError(
                String(localized: "Choose two different languages for this pair in Settings first."))
            return
        }
        // Logged in English, like every log line, not in the interface language.
        let subject = "\(Languages.name(for: pair.first)) ↔ \(Languages.name(for: pair.second))"
        perform("Translate", subject: subject, kind: .translation) {
            try await Translator.translate($0, pair: pair)
        }
    }

    // Rewrites the selected notes into a finished message with `preset`.
    func rewrite(preset: RewritePreset) {
        perform("Rewrite", subject: "preset \(preset.title)", kind: .message) {
            try await Translator.rewrite($0, preset: preset)
        }
    }

    // Copies the selection, runs it through `transform`, and pastes the result
    // back in place. `action` and `subject` label the log lines; `kind` names
    // the result in the popup shown when the paste cannot land.
    private func perform(_ action: String, subject: String, kind: PopupController.ResultKind,
                         transform: @escaping @Sendable (String) async throws -> String) {
        guard !TranslationActivity.shared.isBusy else {
            log.notice("\(action, privacy: .public) ignored: a run is already in progress")
            return
        }
        TranslationActivity.shared.isBusy = true
        interaction.showProgress(kind) { [weak self] in self?.cancel() }
        operation = Task {
            defer {
                interaction.hideProgress()
                TranslationActivity.shared.isBusy = false
                operation = nil
            }
            log.notice("\(action, privacy: .public) started, \(subject, privacy: .public)")
            do {
                try Task.checkCancellation()
                let outcome = try await interaction.run(kind, transform)
                try Task.checkCancellation()
                switch outcome {
                case .noSelection:
                    interaction.showError(
                        String(localized: "No text selected. Select some text first, then try again."))
                case .pasted:
                    log.info("\(action, privacy: .public) done, selection replaced")
                case .result(let result):
                    log.info("\(action, privacy: .public) done, result shown without automatic insertion")
                    interaction.showResult(result, kind)
                }
            } catch where Task.isCancelled || error is CancellationError {
                log.info("\(action, privacy: .public) cancelled")
            } catch {
                // The message can quote the engine's output, so it stays private.
                let kind = String(describing: type(of: error))
                let detail = error.localizedDescription
                log.error("""
                    \(action, privacy: .public) failed (\(kind, privacy: .public)): \(detail, privacy: .private)
                    """)
                if let limit = error as? LimitReachedError {
                    interaction.showLimit(limit.message)
                } else {
                    interaction.showError(error.localizedDescription)
                }
            }
        }
    }

}

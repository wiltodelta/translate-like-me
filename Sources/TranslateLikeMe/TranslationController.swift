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

// Drives the translate and rewrite flows: copy the selection, run it through the
// engine, paste the result back in place. Errors surface in a small cursor-anchored popup.
//
// A run checks the original process, user activity and clipboard ownership
// before insertion. Changed context leaves the result in the popup; the shared
// paste receipt controls when the clipboard can be restored (SelectionWorkflow).
@MainActor
final class TranslationController {
    static let shared = TranslationController()

    private init() {}

    // Translates the selection with `pair` (each pair has its own shortcut).
    func run(pair: LanguagePair) {
        guard pair.isComplete else {
            PopupController.shared.showError(
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
        // Text Input Sources are read here, on the main thread, not in the workflow.
        let copyKey = KeyboardLayout.copyKey
        let pasteKey = KeyboardLayout.pasteKey
        let activity = SelectionActivity()
        let stopMonitoring = activity.monitor()
        Task {
            defer { TranslationActivity.shared.isBusy = false; stopMonitoring() }

            // AX can wait on another process. Monitor input before the lookup,
            // so a focus change during it invalidates Copy without blocking UI.
            let pid = await Task.detached(priority: .userInitiated) { SelectionTarget.focusedPID ?? 0 }.value
            let focusedApp = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
            log.notice("""
                \(action, privacy: .public) started, \(subject, privacy: .public), \
                focused app: \(focusedApp, privacy: .public)
                """)
            let workflow = SelectionWorkflow(access: LiveSelectionAccess(pid: pid, activity: activity,
                                                                        copyKey: copyKey, pasteKey: pasteKey),
                                             didProduceResult: { result in
                                                 await LastResults.shared.record(result, kind: kind)
                                             })
            do {
                switch try await workflow.run(transform: transform) {
                case .noSelection:
                    PopupController.shared.showError(
                        String(localized: "No text selected. Select some text first, then try again."))
                case .pasted:
                    log.info("\(action, privacy: .public) done, selection replaced")
                case .result(let result):
                    log.info("\(action, privacy: .public) done, result shown without automatic insertion")
                    PopupController.shared.showResult(result, kind: kind)
                }
            } catch {
                // The message can quote the engine's output, so it stays private.
                let kind = String(describing: type(of: error))
                let detail = error.localizedDescription
                log.error("""
                    \(action, privacy: .public) failed (\(kind, privacy: .public)): \(detail, privacy: .private)
                    """)
                if let limit = error as? LimitReachedError {
                    PopupController.shared.showLimitReached(limit.message)
                } else {
                    PopupController.shared.showError(error.localizedDescription)
                }
            }
        }
    }

}

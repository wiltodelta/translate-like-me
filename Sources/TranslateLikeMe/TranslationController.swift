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
// A run validates the original AX element, range and text after the engine
// returns. Changed focus, input or clipboard contents leave the result in the
// popup instead of inserting into a stale target (SelectionWorkflow).
@MainActor
final class TranslationController {
    static let shared = TranslationController()

    private init() {}

    // Translates the selection with `pair` (each pair has its own shortcut).
    func run(pair: LanguagePair) {
        guard pair.isComplete else {
            PopupController.shared.showError("Choose two different languages for this pair in Settings first.")
            return
        }
        perform("Translate", subject: pair.title, noun: "Translation") {
            try await Translator.translate($0, pair: pair)
        }
    }

    // Rewrites the selected notes into a finished message with `preset`.
    func rewrite(preset: RewritePreset) {
        perform("Rewrite", subject: "preset \(preset.title)", noun: "Message") {
            try await Translator.rewrite($0, preset: preset)
        }
    }

    // Copies the selection, runs it through `transform`, and pastes the result
    // back in place. `action` and `subject` label the log lines; `noun` names
    // the result in the popup shown when the paste cannot land.
    private func perform(_ action: String, subject: String, noun: String,
                         transform: @escaping @Sendable (String) async throws -> String) {
        guard !TranslationActivity.shared.isBusy else {
            log.info("\(action, privacy: .public) ignored: a run is already in progress")
            return
        }
        TranslationActivity.shared.isBusy = true
        let application = NSWorkspace.shared.frontmostApplication
        let front = application?.bundleIdentifier ?? "unknown"
        let pid = application?.processIdentifier ?? 0
        log.info("""
            \(action, privacy: .public) started, \(subject, privacy: .public), \
            frontmost app: \(front, privacy: .public)
            """)

        Task {
            defer { TranslationActivity.shared.isBusy = false }

            let activity = SelectionActivity()
            let stopMonitoring = activity.monitor()
            defer { stopMonitoring() }
            let workflow = SelectionWorkflow(access: LiveSelectionAccess(pid: pid, activity: activity))
            do {
                switch try await workflow.run(transform: transform) {
                case .noSelection:
                    PopupController.shared.showError("No text selected. Select some text first, then try again.")
                case .pasted:
                    log.info("\(action, privacy: .public) done, selection replaced")
                case .result(let result, let copied):
                    log.info("\(action, privacy: .public) done, result shown without automatic insertion")
                    PopupController.shared.showResult(result, noun: noun, copied: copied)
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

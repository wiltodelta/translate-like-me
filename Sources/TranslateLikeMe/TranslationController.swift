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

// Drives the translate flow: copy the selection, translate, paste the result back
// in place. Errors surface in a small cursor-anchored popup.
//
// Whether the target field is editable is decided after the paste, by checking if
// the selection was actually replaced (see SelectionService.pasteLanded), not
// before it via an Accessibility "is this settable" query. That pre-check was
// unreliable for editable web/Electron fields (including this app's own chat
// input), reporting them as read-only and breaking the common case. Now the paste
// is always attempted; if it did not land (a genuinely read-only selection, e.g. a
// message you are reading rather than writing), the translation is left on the
// clipboard and shown in the popup so it is never lost.
@MainActor
final class TranslationController {
    static let shared = TranslationController()

    private init() {}

    // Translates the selection with `pair` (each pair has its own shortcut).
    func run(pair: LanguagePair) {
        guard !TranslationActivity.shared.isBusy else {
            log.info("Translate ignored: a translation is already running")
            return
        }
        TranslationActivity.shared.isBusy = true
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        log.info("Translate started, pair: \(pair.title, privacy: .public), frontmost app: \(front, privacy: .public)")

        Task {
            defer { TranslationActivity.shared.isBusy = false }

            let original = await offMain { SelectionService.snapshot() }
            let selection = await offMain { SelectionService.copySelection() }
            // The pasteboard as this run left it; a restore is skipped if anything
            // (the user) writes to it after this point.
            let copied = await offMain { SelectionService.changeCount }

            guard let selection,
                  !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                log.warning("No selection copied from \(front, privacy: .public)")
                await offMain { SelectionService.restore(original, ifUnchangedSince: copied) }
                PopupController.shared.showError("No text selected. Select some text first, then press the shortcut.")
                return
            }

            do {
                let translated = try await Translator.translate(selection, pair: pair)
                await offMain { SelectionService.paste(translated) }

                let landed = await offMain { SelectionService.pasteLanded(replacing: selection) }
                log.info("Translated \(selection.count) chars, paste landed: \(landed)")
                if landed {
                    // Restore the original clipboard now that the paste has replaced
                    // the selection.
                    let mark = await offMain { SelectionService.changeCount }
                    try? await Task.sleep(for: .milliseconds(600))
                    await offMain { SelectionService.restore(original, ifUnchangedSince: mark) }
                } else {
                    // Read-only target: keep the translation on the clipboard and
                    // show it so it isn't lost.
                    await offMain { SelectionService.copyToClipboard(translated) }
                    PopupController.shared.showTranslation(translated)
                }
            } catch {
                // The message can quote the engine's output, so it stays private.
                let kind = String(describing: type(of: error))
                let detail = error.localizedDescription
                log.error("Translation failed (\(kind, privacy: .public)): \(detail, privacy: .private)")
                await offMain { SelectionService.restore(original, ifUnchangedSince: copied) }
                if let limit = error as? LimitReachedError {
                    PopupController.shared.showLimitReached(limit.message)
                } else {
                    PopupController.shared.showError(error.localizedDescription)
                }
            }
        }
    }

    // Runs blocking work (pasteboard polling, CGEvent posting) off the main actor.
    private func offMain<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { body() }.value
    }
}

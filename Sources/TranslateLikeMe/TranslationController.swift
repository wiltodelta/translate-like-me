import AppKit
import os

private let log = Logger(subsystem: "com.wiltodelta.translatelikeme", category: "translation")

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
        // A modal alert (an update prompt) holds the main actor, so a run would
        // stall until it closes and then copy from whatever app is in front by
        // then. Show the alert instead.
        if let modal = NSApp.modalWindow {
            log.info("Translate ignored: an alert is open")
            NSApp.activate(ignoringOtherApps: true)
            modal.makeKeyAndOrderFront(nil)
            return
        }
        TranslationActivity.shared.isBusy = true
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        log.info("Translate started, pair: \(pair.title, privacy: .public), frontmost app: \(front, privacy: .public)")

        Task {
            defer { TranslationActivity.shared.isBusy = false }

            let original = await offMain { SelectionService.currentClipboard() }
            let selection = await offMain { SelectionService.copySelection() }

            guard let selection,
                  !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                log.warning("No selection copied from \(front, privacy: .public)")
                await offMain { SelectionService.restoreClipboard(original) }
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
                    try? await Task.sleep(for: .milliseconds(600))
                    await offMain { SelectionService.restoreClipboard(original) }
                } else {
                    // Read-only target: keep the translation on the clipboard and
                    // show it so it isn't lost.
                    await offMain { SelectionService.copyToClipboard(translated) }
                    PopupController.shared.showTranslation(translated)
                }
            } catch {
                log.error("Translation failed: \(error.localizedDescription, privacy: .public)")
                await offMain { SelectionService.restoreClipboard(original) }
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

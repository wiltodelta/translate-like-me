import AppKit

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
// This used to try to detect whether the focused field could actually accept a
// paste (via Accessibility's "is this attribute settable" query) and show the
// translation in a popup instead when it looked read-only, to avoid silently
// pasting into the wrong place (e.g. Slack's message composer while you're
// reading someone else's message). That check turned out to be unreliable for
// ordinary editable fields in modern (web/Electron-based) apps - including this
// app's own chat input - reporting them as "not settable" and routing perfectly
// normal replacements into the popup instead. A wrong "not editable" guess broke
// the common case outright, so it was removed; a wrong "editable" guess in the
// rarer read-only-selection case just wastes a paste.
@MainActor
final class TranslationController {
    static let shared = TranslationController()

    private init() {}

    func run() {
        guard !TranslationActivity.shared.isBusy else { return }
        TranslationActivity.shared.isBusy = true

        Task {
            defer { TranslationActivity.shared.isBusy = false }

            let original = await offMain { SelectionService.currentClipboard() }
            let selection = await offMain { SelectionService.copySelection() }

            guard let selection,
                  !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await offMain { SelectionService.restoreClipboard(original) }
                PopupController.shared.showError("No text selected. Select some text first, then press the shortcut.")
                return
            }

            do {
                let translated = try await Translator.translate(selection)
                await offMain { SelectionService.paste(translated) }
                // Restore the original clipboard once the paste has landed.
                try? await Task.sleep(for: .milliseconds(600))
                await offMain { SelectionService.restoreClipboard(original) }
            } catch {
                await offMain { SelectionService.restoreClipboard(original) }
                PopupController.shared.showError(error.localizedDescription)
            }
        }
    }

    // Runs blocking work (pasteboard polling, CGEvent posting) off the main actor.
    private func offMain<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { body() }.value
    }
}

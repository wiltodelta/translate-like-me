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

                let landed = await offMain { SelectionService.pasteLanded(replacing: selection) }
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

import Cocoa

// Reads the current selection from the frontmost app and pastes replacements,
// by synthesizing Cmd+C / Cmd+V. Requires Accessibility permission.
//
// All methods here block briefly (polling the pasteboard), so call them off the
// main thread.
enum SelectionService {
    private static let pasteboard = NSPasteboard.general

    private enum KeyCode {
        static let cKey: CGKeyCode = 8
        static let vKey: CGKeyCode = 9
    }

    static func currentClipboard() -> String? {
        pasteboard.string(forType: .string)
    }

    static func restoreClipboard(_ value: String?) {
        guard let value else { return }
        copyToClipboard(value)
    }

    static func copyToClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // Copies the current selection and returns it. Returns nil if nothing landed
    // on the pasteboard within the timeout (e.g. no selection).
    static func copySelection() -> String? {
        let before = pasteboard.changeCount
        postKey(KeyCode.cKey)

        let deadline = Date().addingTimeInterval(0.7)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                return pasteboard.string(forType: .string)
            }
            usleep(20_000) // 20ms
        }
        return nil
    }

    // Puts text on the pasteboard and pastes it into the frontmost app.
    static func paste(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Small delay so the new pasteboard contents are settled before Cmd+V.
        usleep(30_000)
        postKey(KeyCode.vKey)
    }

    // After a paste, checks whether the selection was actually replaced. Re-copies
    // the current selection: if it still holds the original text, the paste did not
    // land (a read-only field, e.g. a message you are reading rather than writing).
    // If nothing re-copies within the window, the caret collapsed after a normal
    // paste, so the replacement is assumed to have landed.
    //
    // This is a behavioural check (observe what the paste actually did) rather than
    // an Accessibility "is this settable" query, which was unreliable for editable
    // web/Electron fields and broke the common case.
    static func pasteLanded(replacing original: String) -> Bool {
        usleep(120_000) // let the paste apply before re-reading the selection
        let before = pasteboard.changeCount
        postKey(KeyCode.cKey)

        let deadline = Date().addingTimeInterval(0.35)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                return pasteboard.string(forType: .string) != original
            }
            usleep(20_000) // 20ms
        }
        return true
    }

    private static func postKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let downEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        downEvent?.flags = .maskCommand
        let upEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        upEvent?.flags = .maskCommand
        downEvent?.post(tap: .cghidEventTap)
        upEvent?.post(tap: .cghidEventTap)
    }
}

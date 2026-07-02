import Cocoa

// Reads the current selection from the frontmost app and pastes replacements,
// by synthesizing Cmd+C / Cmd+V. Requires Accessibility permission.
//
// All methods here block briefly (polling the pasteboard), so call them off the
// main thread.
enum SelectionService {
    private static let pasteboard = NSPasteboard.general

    private enum KeyCode {
        static let c: CGKeyCode = 8
        static let v: CGKeyCode = 9
    }

    static func currentClipboard() -> String? {
        pasteboard.string(forType: .string)
    }

    static func restoreClipboard(_ value: String?) {
        guard let value else { return }
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    // Copies the current selection and returns it. Returns nil if nothing landed
    // on the pasteboard within the timeout (e.g. no selection).
    static func copySelection() -> String? {
        let before = pasteboard.changeCount
        postKey(KeyCode.c)

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
        postKey(KeyCode.v)
    }

    private static func postKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

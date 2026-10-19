import AppKit

// Track a single Option hold. Other input cancels it instead of treating an
// ordinary Option combination as a completed dictation.
struct OptionKeyGesture {
    enum Action: Equatable { case press, release, cancel }
    static let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp, .scrollWheel,
        .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    let keyCode: Int
    private var held = false
    private var blocked: Bool

    init(keyCode: Int, initialFlags: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        blocked = !Self.modifiers(initialFlags).isEmpty
    }

    mutating func flagsChanged(keyCode: Int, flags: NSEvent.ModifierFlags) -> Action? {
        let active = Self.modifiers(flags)
        if !active.contains(.option) {
            let fire = held && !blocked && keyCode == self.keyCode && active.isEmpty
            held = false
            blocked = !active.isEmpty
            return fire ? .release : nil
        }
        if keyCode == self.keyCode && !held && !blocked && active == .option {
            held = true
            return .press
        } else {
            let action = cancel()
            blocked = true
            return action
        }
    }

    @discardableResult
    mutating func cancel() -> Action? {
        let active = held && !blocked
        if held { blocked = true }
        return active ? .cancel : nil
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .option, .control, .shift, .function])
    }
}

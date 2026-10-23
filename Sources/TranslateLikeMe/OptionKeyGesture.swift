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

    mutating func handle(type: NSEvent.EventType, keyCode: Int, flags: NSEvent.ModifierFlags,
                         momentumPhase: NSEvent.Phase = []) -> Action? {
        if type == .flagsChanged {
            return flagsChanged(keyCode: keyCode, flags: flags)
        }
        // A previous flick can keep scrolling after the user presses Option.
        if type == .scrollWheel && !momentumPhase.isEmpty { return nil }
        return cancel()
    }

    mutating func flagsChanged(keyCode: Int, flags: NSEvent.ModifierFlags) -> Action? {
        let active = Self.modifiers(flags)
        if !active.contains(.option) {
            let fire = held && !blocked && keyCode == self.keyCode && active.isEmpty
            held = false
            blocked = !active.isEmpty
            return fire ? .release : nil
        }
        if keyCode == self.keyCode && !blocked && active == .option {
            // Repeated flags for the same held key are not a new input gesture.
            guard !held else { return nil }
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

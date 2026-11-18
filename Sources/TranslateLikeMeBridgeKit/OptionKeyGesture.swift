import AppKit

// Track a single Option hold. Other input cancels it instead of treating an
// ordinary Option combination as a completed dictation.
public struct OptionKeyGesture: Sendable {
    public enum Action: String, Codable, Equatable, Sendable { case press, release, cancel }
    public static let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp, .scrollWheel,
        .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    public let keyCode: Int
    private var held = false
    private var blocked: Bool

    public init(keyCode: Int, initialFlags: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        blocked = !Self.modifiers(initialFlags).isEmpty
    }

    public mutating func handle(type: NSEvent.EventType, keyCode: Int, flags: NSEvent.ModifierFlags,
                                momentumPhase: NSEvent.Phase = []) -> Action? {
        if type == .flagsChanged {
            return flagsChanged(keyCode: keyCode, flags: flags)
        }
        // A previous flick can keep scrolling after the user presses Option.
        if type == .scrollWheel && !momentumPhase.isEmpty { return nil }
        return cancel()
    }

    public mutating func flagsChanged(keyCode: Int, flags: NSEvent.ModifierFlags) -> Action? {
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
    public mutating func cancel() -> Action? {
        let active = held && !blocked
        if held { blocked = true }
        return active ? .cancel : nil
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .option, .control, .shift, .function])
    }
}

@MainActor
public final class OptionHoldMonitor {
    public typealias CancellationHandler = @MainActor (NSEvent.EventType, NSEvent.ModifierFlags, NSEvent.Phase) -> Void

    private var gesture: OptionKeyGesture?
    private var monitors: [Any] = []
    private var activeID: UUID?

    public init() {}

    @discardableResult
    public func start(keyCode: Int,
                      onCancellationEvent: CancellationHandler? = nil,
                      onAction: @escaping @MainActor (OptionKeyGesture.Action) -> Void) -> (global: Bool, count: Int) {
        _ = stop()
        let id = UUID()
        activeID = id
        gesture = OptionKeyGesture(keyCode: keyCode, initialFlags: NSEvent.modifierFlags)
        let observe: @Sendable (NSEvent) -> Void = { [weak self] event in
            let type = event.type
            let code = type == .flagsChanged ? Int(event.keyCode) : 0
            let flags = event.modifierFlags
            let momentum = type == .scrollWheel ? event.momentumPhase : []
            MainActor.assumeIsolated {
                guard let self, self.activeID == id else { return }
                let action = self.gesture?.handle(type: type, keyCode: code, flags: flags, momentumPhase: momentum)
                if action == .cancel {
                    onCancellationEvent?(type, flags, momentum)
                }
                if let action { onAction(action) }
            }
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: OptionKeyGesture.events, handler: observe)
        if let global { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: OptionKeyGesture.events, handler: { event in
            observe(event)
            return event
        }) {
            monitors.append(local)
        }
        return (global != nil, monitors.count)
    }

    @discardableResult
    public func cancelCurrentHold() -> OptionKeyGesture.Action? {
        gesture?.cancel()
    }

    @discardableResult
    public func stop() -> OptionKeyGesture.Action? {
        let cancelled = gesture?.cancel()
        activeID = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        gesture = nil
        return cancelled
    }
}

import AppKit
import os

private let targetLog = Logger.app("selection")

// Text goes to whichever process holds keyboard focus, field or custom renderer
// alike, except a password field. Translation also requires it to be the process
// the selection was copied from.
enum SelectionTarget {
    static var destination: pid_t? {
        guard let pid = focusedPID else {
            targetLog.notice("Paste destination unavailable: no focused process")
            return nil
        }
        let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
        if let element = focusedElement(pid: pid), isSecure(element) {
            targetLog.notice("Paste destination is a secure field in \(app, privacy: .public)")
            return nil
        }
        targetLog.notice("Paste destination \(app, privacy: .public), pid \(pid)")
        return pid
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        attribute(element, kAXSubroleAttribute) as? String == "AXSecureTextField"
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    // AX decides whenever it answers, since it names a nonactivating panel
    // holding focus over the frontmost app; frontmost Slack once left it
    // unanswered, and every run read as no selection.
    static var focusedPID: pid_t? {
        focusedPID(accessibility: accessibilityFocusedPID,
                   frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    static func focusedPID(accessibility: pid_t?, frontmost: pid_t?) -> pid_t? {
        accessibility ?? frontmost
    }

    private static var accessibilityFocusedPID: pid_t? {
        let (value, error) = copyAttribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute)
        guard error == .success else {
            targetLog.notice("Accessibility named no focused application, error \(error.rawValue)")
            return nil
        }
        var pid: pid_t = 0
        guard let application = element(value), AXUIElementGetPid(application, &pid) == .success else { return nil }
        return pid
    }

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        element(attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute))
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        let (value, error) = copyAttribute(element, key)
        return error == .success ? value : nil
    }

    private static func copyAttribute(_ element: AXUIElement, _ key: String) -> (CFTypeRef?, AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return (value, error)
    }
}

// Any typing, click or app activation while the engine runs invalidates the
// selection, even if the user switches away and back. Own synthetic Copy/Paste
// events carry a marker and do not count as user activity.
final class SelectionActivity: Sendable {
    enum Invalidation: String, Sendable { case keyboard, pointer, application, unspecified }
    static let eventMarker: Int64 = 0x544C4D
    private let changed = OSAllocatedUnfairLock<Invalidation?>(initialState: nil)
    var isUnchanged: Bool { changed.withLock { $0 == nil } }
    var invalidationReason: String { changed.withLock { $0?.rawValue ?? "none" } }
    func invalidate(_ reason: Invalidation = .unspecified) { changed.withLock { if $0 == nil { $0 = reason } } }

    @MainActor
    func monitor() -> () -> Void {
        let events: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let observe: @Sendable (NSEvent) -> Void = { [self] event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.eventMarker {
                invalidate(event.type == .keyDown ? .keyboard : .pointer)
            }
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: observe)
        let local = NSEvent.addLocalMonitorForEvents(matching: events) { event in observe(event); return event }
        let workspace = NSWorkspace.shared.notificationCenter
        let activation = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                object: nil, queue: .main) { [self] _ in invalidate(.application) }
        return {
            if let global { NSEvent.removeMonitor(global) }
            if let local { NSEvent.removeMonitor(local) }
            workspace.removeObserver(activation)
        }
    }
}

// The real pasteboard and Paste key, shared by translation and dictation.
protocol LivePasteAccess: PasteAccess where Snapshot == SelectionService.Snapshot {
    var pasteKey: CGKeyCode { get }
}

extension LivePasteAccess {
    var changeCount: Int { SelectionService.changeCount }
    func snapshot() -> SelectionService.Snapshot { SelectionService.snapshot() }
    func restore(_ snapshot: SelectionService.Snapshot, ifUnchangedSince mark: Int) {
        SelectionService.restore(snapshot, ifUnchangedSince: mark)
    }
    func paste(_ text: String, to pid: pid_t, ifUnchangedSince mark: Int) -> PromisedPaste? {
        SelectionService.paste(text, to: pid, keyCode: pasteKey, ifUnchangedSince: mark)
    }
}

struct LiveSelectionAccess: SelectionAccess, LivePasteAccess {
    let pid: pid_t
    let activity: SelectionActivity
    let copyKey: CGKeyCode
    let pasteKey: CGKeyCode
    func copySelection() -> CopiedSelection {
        SelectionService.copySelection(from: pid, keyCode: copyKey, activity: activity)
    }
    func destination() -> pid_t? {
        guard activity.isUnchanged else {
            targetLog.notice("Insertion invalidated by \(activity.invalidationReason, privacy: .public) activity")
            return nil
        }
        let destination = SelectionTarget.destination
        guard destination == pid else {
            targetLog.notice("Insertion target unavailable, original pid \(pid), destination \(destination ?? -1)")
            return nil
        }
        return pid
    }
}

struct LiveDictationAccess: LivePasteAccess {
    let pasteKey: CGKeyCode
    func destination() -> pid_t? { SelectionTarget.destination }
}

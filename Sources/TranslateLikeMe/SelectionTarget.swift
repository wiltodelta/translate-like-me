import AppKit
import os

// AX identity plus the selected range and text context, never an editability
// guess. Missing AX evidence disables automatic insertion, not translation.
struct SelectionTarget: @unchecked Sendable {
    let pid: pid_t
    let element: AXUIElement
    let range: CFRange
    let value: String?
    let selectedText: String

    static func capture(pid: pid_t) -> SelectionTarget? {
        guard focusedPID == pid,
              let element = focusedElement(pid: pid),
              let range = selectedRange(of: element),
              let text = attribute(element, kAXSelectedTextAttribute) as? String else { return nil }
        guard range.location >= 0, range.length > 0 else { return nil }
        return Self(pid: pid, element: element, range: range,
                    value: attribute(element, kAXValueAttribute) as? String, selectedText: text)
    }

    func isCurrent() -> Bool {
        guard let current = Self.capture(pid: pid) else { return false }
        return CFEqual(element, current.element) && range.location == current.range.location
            && range.length == current.range.length && selectedText == current.selectedText && value == current.value
    }

    func replacementLanded(_ replacement: String) -> Bool {
        guard Self.focusedPID == pid, let focused = Self.focusedElement(pid: pid),
              CFEqual(focused, element) else { return false }
        if let value, let current = Self.attribute(element, kAXValueAttribute) as? String {
            let original = value as NSString
            guard range.location + range.length <= original.length else { return false }
            return current == original.replacingCharacters(in: NSRange(location: range.location, length: range.length),
                                                            with: replacement)
        }
        // Some web fields expose a range and selected text but no complete value.
        // A collapsed selection after paste is the same behavioral evidence the
        // previous Cmd+C probe used, without another clipboard write.
        return Self.selectedRange(of: element)?.length == 0
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let rangeValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(rangeValue, .cfRange, &range) ? range : nil
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static var focusedPID: pid_t? {
        guard let application = element(attribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute)) else {
            return nil
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(application, &pid) == .success else { return nil }
        return pid
    }

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        element(attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute))
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
}

// Invalidate even if the user edits and then restores the same AX text, or
// switches away and back while the engine is running. Own synthetic Copy/Paste
// events carry a marker and do not count as user activity.
final class SelectionActivity: Sendable {
    static let eventMarker: Int64 = 0x544C4D
    private let changed = OSAllocatedUnfairLock(initialState: false)
    var isUnchanged: Bool { changed.withLock { !$0 } }
    func invalidate() { changed.withLock { $0 = true } }

    @MainActor
    func monitor() -> () -> Void {
        let events: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let observe: @Sendable (NSEvent) -> Void = { [self] event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.eventMarker { invalidate() }
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: observe)
        let local = NSEvent.addLocalMonitorForEvents(matching: events) { event in observe(event); return event }
        let workspace = NSWorkspace.shared.notificationCenter
        let activation = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                object: nil, queue: .main) { [self] _ in invalidate() }
        return {
            if let global { NSEvent.removeMonitor(global) }
            if let local { NSEvent.removeMonitor(local) }
            workspace.removeObserver(activation)
        }
    }
}

struct LiveSelectionAccess: SelectionAccess {
    let pid: pid_t
    let activity: SelectionActivity
    var changeCount: Int { SelectionService.changeCount }
    func snapshot() -> SelectionService.Snapshot { SelectionService.snapshot() }
    func restore(_ snapshot: SelectionService.Snapshot, ifUnchangedSince mark: Int) {
        SelectionService.restore(snapshot, ifUnchangedSince: mark)
    }
    func captureTarget() -> SelectionTarget? { SelectionTarget.capture(pid: pid) }
    func copySelection() -> CopiedSelection { SelectionService.copySelection(from: pid, activity: activity) }
    func isCurrent(_ target: SelectionTarget) -> Bool { activity.isUnchanged && target.isCurrent() }
    func paste(_ text: String, into target: SelectionTarget, ifUnchangedSince mark: Int) -> PasteAttempt? {
        SelectionService.paste(text, into: target, ifUnchangedSince: mark, activity: activity)
    }
    func replacementLanded(_ text: String, in target: SelectionTarget) -> Bool { target.replacementLanded(text) }
    func copyResult(_ text: String, ifUnchangedSince mark: Int) -> Bool {
        guard changeCount == mark else { return false }
        SelectionService.copyToClipboard(text)
        return true
    }
}

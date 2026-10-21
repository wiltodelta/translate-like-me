import AppKit
import os

private let targetLog = Logger.app("selection")

// Text targets retain AX identity, selection and value; translation needs that
// evidence for automatic insertion.
struct SelectionTarget: @unchecked Sendable {
    let pid: pid_t
    let element: AXUIElement
    let range: CFRange
    let value: String?
    let selectedText: String

    static func capture(pid: pid_t) -> SelectionTarget? {
        guard focusedPID == pid, let element = focusedElement(pid: pid), !isSecure(element),
              let range = selectedRange(of: element), range.length > 0,
              let text = attribute(element, kAXSelectedTextAttribute) as? String else { return nil }
        return Self(pid: pid, element: element, range: range,
                    value: attribute(element, kAXValueAttribute) as? String, selectedText: text)
    }

    // Dictation goes to whichever process holds keyboard focus now, field or
    // custom renderer alike, except a password field.
    static var dictationDestination: pid_t? {
        guard let pid = focusedPID else {
            targetLog.notice("Dictation destination unavailable: no focused process")
            return nil
        }
        let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
        if let element = focusedElement(pid: pid), isSecure(element) {
            targetLog.notice("Dictation destination is a secure field in \(app, privacy: .public)")
            return nil
        }
        targetLog.notice("Dictation destination \(app, privacy: .public), pid \(pid)")
        return pid
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        attribute(element, kAXSubroleAttribute) as? String == "AXSecureTextField"
    }

    func isCurrent() -> Bool {
        guard let current = Self.capture(pid: pid) else {
            targetLog.notice("Insertion target unavailable, original pid \(pid), focused pid \(Self.focusedPID ?? -1)")
            return false
        }
        let sameElement = CFEqual(element, current.element)
        let sameRange = range.location == current.range.location && range.length == current.range.length
        let sameSelection = selectedText == current.selectedText
        let sameValue = value == current.value
        let unchanged = sameElement && sameRange && sameSelection && sameValue
        if !unchanged {
            targetLog.notice("""
                Insertion target changed: same element \(sameElement), same range \(sameRange), \
                same selection \(sameSelection), same value \(sameValue)
                """)
        }
        return unchanged
    }

    func replacementLanded(_ replacement: String) -> Bool {
        let focusedPID = Self.focusedPID
        let focused = Self.focusedElement(pid: pid)
        let sameElement = focused.map { CFEqual($0, element) } ?? false
        guard focusedPID == pid, sameElement else {
            targetLog.notice("""
                Paste not confirmed: original pid \(pid), focused pid \(focusedPID ?? -1), \
                same focused element \(sameElement)
                """)
            return false
        }
        let currentRange = Self.selectedRange(of: element)
        if let value, let current = Self.attribute(element, kAXValueAttribute) as? String {
            let original = value as NSString
            guard range.location <= original.length, range.length <= original.length - range.location else {
                targetLog.notice("""
                    Paste not confirmed: original range outside AX value, location \(range.location), \
                    length \(range.length), value length \(original.length)
                    """)
                return false
            }
            let expected = original.replacingCharacters(in: NSRange(location: range.location, length: range.length),
                                                       with: replacement)
            let matched = current == expected
            if !matched {
                let sameIgnoringNewlines = current.trimmingCharacters(in: .newlines)
                    == expected.trimmingCharacters(in: .newlines)
                targetLog.notice("""
                    Paste not confirmed: AX value differs, original length \(original.length), \
                    expected length \(expected.utf16.count), current length \(current.utf16.count), \
                    same ignoring edge newlines \(sameIgnoringNewlines), \
                    current range \(currentRange?.location ?? -1):\(currentRange?.length ?? -1)
                    """)
            }
            return matched
        }
        // Some web fields expose a range and selected text but no complete value.
        // A collapsed selection after paste is the same behavioral evidence the
        // previous Cmd+C probe used, without another clipboard write.
        let matched = currentRange.map { $0.length == 0 } ?? false
        if !matched {
            targetLog.notice("""
                Paste not confirmed: caret evidence missing, original range \(range.location):\(range.length), \
                replacement length \(replacement.utf16.count), \
                current range \(currentRange?.location ?? -1):\(currentRange?.length ?? -1)
                """)
        }
        return matched
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        selectionRange(from: attribute(element, kAXSelectedTextRangeAttribute))
    }

    static func selectionRange(from value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let rangeValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return range
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

// Invalidate even if the user edits and then restores the same AX text, or
// switches away and back while the engine is running. Own synthetic Copy/Paste
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
    func isCurrent(_ target: SelectionTarget) -> Bool {
        guard activity.isUnchanged else {
            targetLog.notice("Insertion invalidated by \(activity.invalidationReason, privacy: .public) activity")
            return false
        }
        return target.isCurrent()
    }
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

struct LiveDictationAccess: DictationPasteAccess {
    let pasteKey: CGKeyCode
    var changeCount: Int { SelectionService.changeCount }
    func snapshot() -> SelectionService.Snapshot { SelectionService.snapshot() }
    func restore(_ snapshot: SelectionService.Snapshot, ifUnchangedSince mark: Int) {
        SelectionService.restore(snapshot, ifUnchangedSince: mark)
    }
    func destination() -> pid_t? { SelectionTarget.dictationDestination }
    func paste(_ text: String, to pid: pid_t, ifUnchangedSince mark: Int) -> DictationPaste? {
        SelectionService.pasteAtCursor(text, to: pid, keyCode: pasteKey, ifUnchangedSince: mark)
    }
}

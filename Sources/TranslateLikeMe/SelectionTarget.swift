import AppKit
import os

private let targetLog = Logger.app("selection")

// Text targets retain AX identity, selection and value. Dictation may retain a
// standard window when a custom renderer exposes no field. Translation still
// needs text evidence for automatic insertion.
struct SelectionTarget: @unchecked Sendable {
    let pid: pid_t
    let element: AXUIElement
    let range: CFRange
    let value: String?
    let selectedText: String
    var allowsCaret = false
    var isWindowOnly = false

    static func capture(pid: pid_t, allowingCaret: Bool = false) -> SelectionTarget? {
        guard focusedPID == pid, let element = focusedElement(pid: pid),
              attribute(element, kAXSubroleAttribute) as? String != "AXSecureTextField" else { return nil }
        guard let range = selectedRange(of: element) else {
            // Custom renderers may expose only their focused native window.
            // Dictation can keep that window and continuous activity as evidence;
            // translation still requires an actual text selection.
            guard let window = Self.element(attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)),
                  permitsWindowCapture(allowingCaret: allowingCaret,
                                       role: attribute(element, kAXRoleAttribute) as? String,
                                       subrole: attribute(element, kAXSubroleAttribute) as? String,
                                       isFocusedWindow: CFEqual(element, window),
                                       childSubroles: windowChildSubroles(window)) else { return nil }
            return Self(pid: pid, element: window, range: CFRange(location: 0, length: 0),
                        value: nil, selectedText: "", allowsCaret: true, isWindowOnly: true)
        }
        guard range.length > 0 || allowingCaret else { return nil }
        let selected = attribute(element, kAXSelectedTextAttribute) as? String
        guard let text = selected ?? (range.length == 0 ? "" : nil) else { return nil }
        return Self(pid: pid, element: element, range: range,
                    value: attribute(element, kAXValueAttribute) as? String,
                    selectedText: text, allowsCaret: allowingCaret)
    }

    static func permitsWindowCapture(allowingCaret: Bool, role: String?, subrole: String?,
                                     isFocusedWindow: Bool, childSubroles: [String?]?) -> Bool {
        guard allowingCaret, role == kAXWindowRole, subrole == kAXStandardWindowSubrole,
              isFocusedWindow, let childSubroles else { return false }
        let chrome: Set<String> = [kAXCloseButtonSubrole, kAXMinimizeButtonSubrole,
                                   kAXZoomButtonSubrole, "AXFullScreenButton"]
        return childSubroles.allSatisfy { child in child.map { chrome.contains($0) } ?? false }
    }

    private static func windowChildSubroles(_ window: AXUIElement) -> [String?]? {
        (attribute(window, kAXChildrenAttribute) as? [AXUIElement])?.map {
            attribute($0, kAXSubroleAttribute) as? String
        }
    }

    func isCurrent() -> Bool {
        guard let current = Self.capture(pid: pid, allowingCaret: allowsCaret) else {
            targetLog.notice("Insertion target unavailable, original pid \(pid), focused pid \(Self.focusedPID ?? -1)")
            return false
        }
        let sameElement = CFEqual(element, current.element)
        let sameRange = range.location == current.range.location && range.length == current.range.length
        let sameSelection = selectedText == current.selectedText
        let sameValue = value == current.value
        let sameScope = isWindowOnly == current.isWindowOnly
        let unchanged = sameScope && sameElement && sameRange && sameSelection && sameValue
        if !unchanged {
            targetLog.notice("""
                Insertion target changed: same element \(sameElement), same range \(sameRange), \
                same selection \(sameSelection), same value \(sameValue), same scope \(sameScope)
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
            let matched = replacementMatches(current, expected: expected, currentRange: currentRange)
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
        let matched = currentRange.map {
            $0.length == 0 && (!allowsCaret || $0.location == range.location + replacement.utf16.count)
        } ?? false
        if !matched {
            targetLog.notice("""
                Paste not confirmed: caret evidence missing, original range \(range.location):\(range.length), \
                replacement length \(replacement.utf16.count), \
                current range \(currentRange?.location ?? -1):\(currentRange?.length ?? -1)
                """)
        }
        return matched
    }

    func replacementMatches(_ current: String, expected: String, currentRange: CFRange?) -> Bool {
        if current == expected { return true }
        // Empty rich editors can expose an LF placeholder that disappears on
        // paste. Keep this exception separate from actual user whitespace.
        guard allowsCaret, value == "\n", range.location == 0, range.length == 0,
              let currentRange, currentRange.length == 0,
              currentRange.location == current.utf16.count else { return false }
        return expected == current + "\n"
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

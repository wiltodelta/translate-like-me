import AppKit
import os

private let targetLog = Logger.app("selection")

// Text goes to whichever process holds keyboard focus, field or custom renderer
// alike, except a password field. Translation also requires it to be the process
// the selection was copied from.
enum SelectionTarget {
    private static let rpcTimeout: Float = 0.2
    static let snapshotBudget: Duration = .milliseconds(250)

    private enum SecurityClassification {
        case nonSecure, secure, unknown
    }

    static var destination: pid_t? {
        resolveDestination(pid: focusedPID, deadline: nil)?.pid
    }

    private static func classifySecurity(_ element: AXUIElement,
                                         deadline: ContinuousClock.Instant? = nil) -> SecurityClassification {
        let (value, error) = copyAttribute(element, kAXSubroleAttribute, deadline: deadline)
        switch error {
        case .success:
            return (value as? String) == "AXSecureTextField" ? .secure : .nonSecure
        case .attributeUnsupported, .noValue:
            return .nonSecure
        default:
            return .unknown
        }
    }

    private static func element(_ value: CFTypeRef?, deadline: ContinuousClock.Instant? = nil) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let target = unsafeDowncast(value, to: AXUIElement.self)
        guard arm(target, until: deadline) else { return nil }
        return target
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

    static func dictationSnapshot(pid: pid_t? = focusedPID,
                                  budget: Duration = snapshotBudget) -> DictationDestinationSnapshot {
        guard let pid else { return DictationDestinationSnapshot() }
        let deadline = ContinuousClock.now.advanced(by: budget)
        let app = AXUIElementCreateApplication(pid)
        let (rawFocused, focusError) = copyAttribute(app, kAXFocusedUIElementAttribute, deadline: deadline)
        var verifiedFocused: AXUIElement?
        switch focusError {
        case .success:
            guard let candidate = element(rawFocused, deadline: deadline),
                  classifySecurity(candidate, deadline: deadline) == .nonSecure else {
                return DictationDestinationSnapshot()
            }
            verifiedFocused = candidate
        case .attributeUnsupported, .noValue:
            break
        default:
            return DictationDestinationSnapshot()
        }
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName
        let windowTitle = snapshotWindowTitle(app: app, deadline: deadline)
        let surrounding = verifiedFocused.flatMap { surroundingText(in: $0, deadline: deadline) }
        return DictationDestinationSnapshot(appName: appName, windowTitle: windowTitle,
                                            surroundingText: surrounding)
    }

    static func dictationTarget(pid: pid_t? = focusedPID,
                                budget: Duration = snapshotBudget) -> (pid: pid_t, beforeCaret: Character?)? {
        let deadline = ContinuousClock.now.advanced(by: budget)
        guard let resolved = resolveDestination(pid: pid, deadline: deadline) else { return nil }
        let before = resolved.verifiedFocused.flatMap { characterBeforeCaret(in: $0, deadline: deadline) }
        return (resolved.pid, before)
    }

    private static func resolveDestination(
        pid: pid_t?, deadline: ContinuousClock.Instant?
    ) -> (pid: pid_t, verifiedFocused: AXUIElement?)? {
        guard let pid else {
            targetLog.notice("Paste destination unavailable: no focused process")
            return nil
        }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
        let app = AXUIElementCreateApplication(pid)
        if deadline == nil { AXUIElementSetMessagingTimeout(app, rpcTimeout) }
        var verified: AXUIElement?
        if let focused = element(attribute(app, kAXFocusedUIElementAttribute, deadline: deadline), deadline: deadline) {
            switch classifySecurity(focused, deadline: deadline) {
            case .secure:
                targetLog.notice("Paste destination is a secure field in \(bundle, privacy: .public)")
                return nil
            case .nonSecure:
                verified = focused
            case .unknown:
                verified = nil
            }
        }
        targetLog.notice("Paste destination \(bundle, privacy: .public), pid \(pid)")
        return (pid, verified)
    }

    private static func snapshotWindowTitle(app: AXUIElement, deadline: ContinuousClock.Instant) -> String? {
        let primary = element(attribute(app, kAXFocusedWindowAttribute, deadline: deadline), deadline: deadline)
        let window = primary ?? element(attribute(app, kAXMainWindowAttribute, deadline: deadline), deadline: deadline)
        guard let window else { return nil }
        return attribute(window, kAXTitleAttribute, deadline: deadline) as? String
    }

    private static func characterBeforeCaret(in focused: AXUIElement,
                                             deadline: ContinuousClock.Instant) -> Character? {
        guard let selection = selectedRange(in: focused, deadline: deadline),
              selection.length == 0, selection.location > 0 else { return nil }
        switch rangedSliceBefore(caret: selection.location, in: focused, deadline: deadline) {
        case .slice(let text):
            return text.last
        case .aborted:
            return nil
        case .unsupported:
            let count = attribute(focused, kAXNumberOfCharactersAttribute, deadline: deadline) as? Int
            guard let value = boundedValue(in: focused, knownCount: count, deadline: deadline) else { return nil }
            return DictationContext.characterBeforeCaret(in: value, selection: selection)
        }
    }

    private enum RangedQuery {
        case slice(String)
        case unsupported
        case aborted
    }

    private static func rangedSliceBefore(caret: Int, in element: AXUIElement,
                                          deadline: ContinuousClock.Instant) -> RangedQuery {
        let firstSpan = min(16, caret)
        let (first, firstError) = string(in: element, range: CFRange(location: caret - firstSpan, length: firstSpan),
                                         deadline: deadline)
        if let first, !first.isEmpty { return .slice(first) }
        if isRangeUnsupportedOrTimedOut(firstError) {
            return firstError == .cannotComplete ? .aborted : .unsupported
        }
        guard caret > firstSpan else { return .unsupported }
        let secondSpan = min(17, caret)
        let (second, secondError) = string(
            in: element, range: CFRange(location: caret - secondSpan, length: secondSpan), deadline: deadline
        )
        if let second, !second.isEmpty { return .slice(second) }
        return secondError == .cannotComplete ? .aborted : .unsupported
    }

    private static func isRangeUnsupportedOrTimedOut(_ error: AXError) -> Bool {
        switch error {
        case .parameterizedAttributeUnsupported, .attributeUnsupported,
             .cannotComplete, .apiDisabled, .invalidUIElement:
            return true
        default:
            return false
        }
    }

    private static func arm(_ element: AXUIElement, until deadline: ContinuousClock.Instant?) -> Bool {
        guard let deadline else {
            AXUIElementSetMessagingTimeout(element, rpcTimeout)
            return true
        }
        let seconds = ContinuousClock.now.duration(to: deadline) / .seconds(1)
        guard seconds > 0.005 else { return false }
        AXUIElementSetMessagingTimeout(element, min(rpcTimeout, max(0.02, Float(seconds))))
        return true
    }

    private static func selectedRange(in element: AXUIElement, deadline: ContinuousClock.Instant?) -> NSRange? {
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute, deadline: deadline),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(raw, to: AXValue.self), .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func string(in element: AXUIElement, range: CFRange,
                               deadline: ContinuousClock.Instant?) -> (String?, AXError) {
        guard range.location >= 0, range.length >= 0 else { return (nil, .illegalArgument) }
        guard arm(element, until: deadline) else { return (nil, .cannotComplete) }
        var mutable = range
        guard let parameter = AXValueCreate(.cfRange, &mutable) else { return (nil, .failure) }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value
        )
        return (error == .success ? (value as? String) : nil, error)
    }

    // Require an explicit bounded character count before copying full AXValue,
    // so controls without ranged AX cannot stream multi-megabyte buffers over IPC.
    private static func boundedValue(in element: AXUIElement, knownCount: Int?,
                                     deadline: ContinuousClock.Instant?) -> String? {
        guard let count = knownCount, count >= 0, count <= 32_768,
              let value = attribute(element, kAXValueAttribute, deadline: deadline) as? String,
              value.utf16.count <= 32_768 else {
            return nil
        }
        return value
    }

    private static func surroundingText(in element: AXUIElement, deadline: ContinuousClock.Instant) -> String? {
        let count = attribute(element, kAXNumberOfCharactersAttribute, deadline: deadline) as? Int
        let selection = selectedRange(in: element, deadline: deadline)
        if let selection {
            switch surroundingSlice(in: element, selection: selection, knownCount: count, deadline: deadline) {
            case .slice(let text):
                return text.isEmpty ? nil : text
            case .aborted:
                return nil
            case .unsupported:
                break
            }
        }
        guard let value = boundedValue(in: element, knownCount: count, deadline: deadline) else { return nil }
        let fallbackRange = selection ?? NSRange(location: value.utf16.count, length: 0)
        return DictationContext.surroundingText(in: value, selection: fallbackRange)
    }

    private static func surroundingSlice(in element: AXUIElement, selection: NSRange,
                                         knownCount: Int?, deadline: ContinuousClock.Instant) -> RangedQuery {
        let beforeStart = max(0, selection.location - DictationContext.beforeCaretLimit)
        let beforeLength = selection.location - beforeStart
        var before: String?
        if beforeLength > 0 {
            let (text, error) = string(
                in: element, range: CFRange(location: beforeStart, length: beforeLength), deadline: deadline
            )
            if error == .cannotComplete { return .aborted }
            if isRangeUnsupportedOrTimedOut(error) { return .unsupported }
            before = text
        }
        var after: String?
        let (afterStart, overflow) = selection.location.addingReportingOverflow(selection.length)
        if !overflow {
            let requestedAfter = knownCount.map { min(DictationContext.afterCaretLimit, max(0, $0 - afterStart)) }
                ?? DictationContext.afterCaretLimit
            if requestedAfter > 0 {
                let (text, error) = string(
                    in: element, range: CFRange(location: afterStart, length: requestedAfter), deadline: deadline
                )
                if error == .cannotComplete { return .aborted }
                if before == nil, isRangeUnsupportedOrTimedOut(error) { return .unsupported }
                after = text
            }
        }
        guard before != nil || after != nil else {
            return knownCount == 0 ? .slice("") : .unsupported
        }
        let combined = [before, after].compactMap { $0 }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .slice(combined)
    }

    private static func attribute(_ element: AXUIElement, _ key: String,
                                  deadline: ContinuousClock.Instant? = nil) -> CFTypeRef? {
        let (value, error) = copyAttribute(element, key, deadline: deadline)
        return error == .success ? value : nil
    }

    private static func copyAttribute(_ element: AXUIElement, _ key: String,
                                      deadline: ContinuousClock.Instant? = nil) -> (CFTypeRef?, AXError) {
        if let deadline {
            guard arm(element, until: deadline) else { return (nil, .cannotComplete) }
        }
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
    func dictationTarget() -> (pid: pid_t, beforeCaret: Character?)? { SelectionTarget.dictationTarget() }
}

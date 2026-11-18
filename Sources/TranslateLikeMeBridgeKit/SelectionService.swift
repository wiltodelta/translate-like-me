import Cocoa
import os
import Synchronization

private let selectionLog = Logger.app("selection")

// Reads the current selection from the focused app and pastes replacements,
// by synthesizing Cmd+C / Cmd+V. Requires Accessibility permission.
//
// All methods here block briefly (polling the pasteboard), so call them off the
// main thread.
public enum SelectionService {
    // The system's Accessibility prompt (it offers to open System Settings);
    // does nothing once access is granted.
    public static func promptForAccessibility() {
        // The value of kAXTrustedCheckOptionPrompt, a C global Swift 6 treats as
        // shared mutable state.
        let key = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    public static func openAccessibilitySettings() {
        promptForAccessibility()
        openPrivacySettings("Accessibility")
    }

    private static var pasteboard: NSPasteboard { .general }

    // Every item and type on the pasteboard, so putting it back keeps rich text,
    // images and files, not just the plain string; an empty snapshot restores
    // an empty pasteboard.
    public struct Snapshot: Sendable {
        public let items: [[String: Data]]
        public init(items: [[String: Data]]) { self.items = items }
    }

    public static func snapshot(of board: NSPasteboard = .general) -> Snapshot {
        Snapshot(items: (board.pasteboardItems ?? []).map { item in
            var types: [String: Data] = [:]
            for type in item.types { types[type.rawValue] = item.data(forType: type) }
            return types
        })
    }

    public static var changeCount: Int { pasteboard.changeCount }

    // Puts the snapshot back, unless something else wrote to the pasteboard
    // after `expected` (the user copying something meanwhile wins).
    public static func restore(_ snapshot: Snapshot, ifUnchangedSince expected: Int,
                               on board: NSPasteboard = .general) {
        guard board.changeCount == expected else { return }
        board.clearContents()
        let items = snapshot.items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }

    public static func copyToClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // Copies the current selection and returns it. Returns nil if nothing landed
    // on the pasteboard within the timeout (e.g. no selection).
    public static func copySelection(from pid: pid_t, keyCode: CGKeyCode,
                                     activity: SelectionActivity) -> CopiedSelection {
        let before = pasteboard.changeCount
        let focused = SelectionTarget.focusedPID
        guard activity.isUnchanged, focused == pid else {
            selectionLog.notice("""
                Copy skipped: target pid \(pid), focused pid \(focused ?? -1), \
                activity \(activity.invalidationReason, privacy: .public), Accessibility \(AXIsProcessTrusted())
                """)
            return CopiedSelection(text: nil, changeCount: nil)
        }
        postKey(keyCode, to: pid)
        let deadline = Date().addingTimeInterval(0.7)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                let mark = pasteboard.changeCount
                let text = pasteboard.string(forType: .string)
                guard activity.isUnchanged, pasteboard.changeCount == mark else {
                    selectionLog.notice("""
                        Copy interrupted: activity \(activity.invalidationReason, privacy: .public), \
                        clipboard changed again \(pasteboard.changeCount != mark)
                        """)
                    return CopiedSelection(text: nil, changeCount: nil)
                }
                if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    selectionLog.notice("Copy returned no nonblank plain text")
                }
                return CopiedSelection(text: text, changeCount: mark)
            }
            usleep(20_000)
        }
        selectionLog.notice("Copy timed out without a clipboard change, target pid \(pid)")
        return CopiedSelection(text: nil, changeCount: nil)
    }

    // The string is promised rather than written, so the receipt records whether
    // any process read it: a paste that never reads the clipboard did not happen.
    public static func paste(_ text: String, to pid: pid_t, keyCode: CGKeyCode,
                             ifUnchangedSince expected: Int) -> PromisedPaste? {
        guard pasteboard.changeCount == expected else { return nil }
        let receipt = PasteReceipt(text: text)
        let mark = writeTransient(receipt.promisedItem())
        postKey(keyCode, to: pid)
        return PromisedPaste(changeCount: mark, receipt: receipt)
    }

    // TransientType keeps clipboard managers from reading or recording our
    // writes. Returns the change count that marks this write as ours.
    public static func writeTransient(_ item: NSPasteboardItem, on board: NSPasteboard = .general) -> Int {
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        board.clearContents()
        board.writeObjects([item])
        return board.changeCount
    }

    private static func postKey(_ keyCode: CGKeyCode, to pid: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let downEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        downEvent?.flags = .maskCommand
        let upEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        upEvent?.flags = .maskCommand
        downEvent?.setIntegerValueField(.eventSourceUserData, value: SelectionActivity.eventMarker)
        downEvent?.postToPid(pid)
        upEvent?.setIntegerValueField(.eventSourceUserData, value: SelectionActivity.eventMarker)
        upEvent?.postToPid(pid)
    }
}

public struct PromisedPaste: Sendable {
    public let changeCount: Int
    public let receipt: PasteReceipt
    public init(changeCount: Int, receipt: PasteReceipt) {
        self.changeCount = changeCount
        self.receipt = receipt
    }
}

public final class PasteReceipt: NSObject, NSPasteboardItemDataProvider, Sendable {
    private let text: String
    private let read = OSAllocatedUnfairLock(initialState: false)
    public var wasRead: Bool { read.withLock { $0 } }

    public init(text: String) { self.text = text }

    public func promisedItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.string])
        return item
    }

    // Also called by test fakes that simulate the destination's read.
    public func recordRead() { read.withLock { $0 = true } }

    public func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                           provideDataForType type: NSPasteboard.PasteboardType) {
        recordRead()
        item.setString(text, forType: type)
    }
}

import Cocoa
import os

private let selectionLog = Logger.app("selection")

// Reads the current selection from the focused app and pastes replacements,
// by synthesizing Cmd+C / Cmd+V. Requires Accessibility permission.
//
// All methods here block briefly (polling the pasteboard), so call them off the
// main thread.
enum SelectionService {
    // The system's Accessibility prompt (it offers to open System Settings);
    // does nothing once access is granted.
    static func promptForAccessibility() {
        // The value of kAXTrustedCheckOptionPrompt, a C global Swift 6 treats as
        // shared mutable state.
        let key = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static var pasteboard: NSPasteboard { .general }

    // Every item and type on the pasteboard, so putting it back keeps rich text,
    // images and files, not just the plain string; an empty snapshot restores
    // an empty pasteboard.
    struct Snapshot: Sendable {
        let items: [[String: Data]]
    }

    static func snapshot(of board: NSPasteboard = pasteboard) -> Snapshot {
        Snapshot(items: (board.pasteboardItems ?? []).map { item in
            var types: [String: Data] = [:]
            for type in item.types { types[type.rawValue] = item.data(forType: type) }
            return types
        })
    }

    static var changeCount: Int { pasteboard.changeCount }

    // Puts the snapshot back, unless something else wrote to the pasteboard
    // after `expected` (the user copying something meanwhile wins).
    static func restore(_ snapshot: Snapshot, ifUnchangedSince expected: Int,
                        on board: NSPasteboard = pasteboard) {
        guard board.changeCount == expected else { return }
        board.clearContents()
        let items = snapshot.items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }

    static func copyToClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // Copies the current selection and returns it. Returns nil if nothing landed
    // on the pasteboard within the timeout (e.g. no selection).
    static func copySelection(from pid: pid_t, keyCode: CGKeyCode, activity: SelectionActivity) -> CopiedSelection {
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
    static func paste(_ text: String, to pid: pid_t, keyCode: CGKeyCode,
                      ifUnchangedSince expected: Int) -> PromisedPaste? {
        guard pasteboard.changeCount == expected else { return nil }
        let receipt = PasteReceipt(text: text)
        let mark = writeTransient(receipt.promisedItem())
        postKey(keyCode, to: pid)
        return PromisedPaste(changeCount: mark, receipt: receipt)
    }

    // TransientType keeps clipboard managers from reading or recording our
    // writes. Returns the change count that marks this write as ours.
    static func writeTransient(_ item: NSPasteboardItem, on board: NSPasteboard = pasteboard) -> Int {
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

struct PromisedPaste: Sendable {
    let changeCount: Int
    let receipt: PasteReceipt
}

final class PasteReceipt: NSObject, NSPasteboardItemDataProvider, Sendable {
    private let text: String
    private let read = OSAllocatedUnfairLock(initialState: false)
    var wasRead: Bool { read.withLock { $0 } }

    init(text: String) { self.text = text }

    func promisedItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.string])
        return item
    }

    // Also called by test fakes that simulate the destination's read.
    func recordRead() { read.withLock { $0 = true } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        recordRead()
        item.setString(text, forType: type)
    }
}

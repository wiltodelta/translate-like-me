import Foundation
import os

private let deliveryLog = Logger.app("selection")

// The adapter owns AX, key posting and the pasteboard, so tests run the whole
// destination/paste/receipt/restore flow without real input.
protocol PasteAccess: Sendable {
    associatedtype Snapshot: Sendable
    var changeCount: Int { get }
    func snapshot() -> Snapshot
    func restore(_ snapshot: Snapshot, ifUnchangedSince mark: Int)
    // The process that may receive the text now, or nil: no focused process, a
    // secure text field, or a translation whose context changed.
    func destination() -> pid_t?
    func paste(_ text: String, to pid: pid_t, ifUnchangedSince mark: Int) -> PromisedPaste?
}

// Translation, Rewrite and dictation all insert text this way. The destination's
// read of the promised clipboard string is the delivery proof: AX cannot see into
// custom renderers, and a fixed wait restored the clipboard before a busy app
// read it, so the app pasted the user's older clipboard.
struct PasteDelivery<Access: PasteAccess>: Sendable {
    static var readDeadline: Duration { .seconds(3) }
    // Hold our clipboard briefly after the read: an app may read it more than once.
    static var holdAfterRead: Duration { .milliseconds(300) }
    static var minimumHold: Duration { .milliseconds(700) }
    static var step: Duration { .milliseconds(50) }

    let access: Access
    var pause: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    // Dictation: the clipboard is snapshotted just before writing.
    func insert(_ text: String) async throws -> Bool {
        try Task.checkCancellation()
        let mark = access.changeCount
        return try await deliver(text, restoring: access.snapshot(), ifUnchangedSince: mark)
    }

    // Pastes once into the current destination, then restores `original` unless
    // a newer copy took the clipboard. Returns whether the destination read the
    // text; an unread paste is never retried. Writes nothing when there is no
    // destination or the clipboard changed after `mark`.
    func deliver(_ text: String, restoring original: Access.Snapshot,
                 ifUnchangedSince mark: Int) async throws -> Bool {
        guard let pid = access.destination() else { return false }
        guard let paste = access.paste(text, to: pid, ifUnchangedSince: mark) else {
            deliveryLog.notice("Paste skipped: the clipboard changed before writing")
            return false
        }
        // A newer clipboard copy always wins, including after cancellation.
        defer { access.restore(original, ifUnchangedSince: paste.changeCount) }
        var waited = Duration.zero
        var readAt: Duration?
        while waited < Self.readDeadline {
            await pause(Self.step)
            waited += Self.step
            try Task.checkCancellation()
            if readAt == nil, paste.receipt.wasRead { readAt = waited }
            if let readAt, waited >= max(readAt + Self.holdAfterRead, Self.minimumHold) { break }
        }
        let latency = readAt.map { Int($0 / .milliseconds(1)) } ?? -1
        deliveryLog.notice("Paste to pid \(pid) read \(readAt != nil) after \(latency) ms")
        return readAt != nil
    }
}

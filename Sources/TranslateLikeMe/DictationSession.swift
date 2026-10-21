import Foundation
import os

private let deliveryLog = Logger.app("dictation")

// Every asynchronous completion must belong to the current session and phase.
// Cancellation invalidates identity immediately, even if Core ML is still busy.
struct DictationSession {
    enum ReleaseAction: Equatable { case stop, ignore }
    enum Phase: Equatable {
        case disabled, preparing, ready, starting, recording, recognizing, cancelling, failed
    }
    private(set) var id = UUID()
    private(set) var phase: Phase = .disabled

    mutating func begin(_ phase: Phase) -> UUID {
        id = UUID()
        self.phase = phase
        return id
    }

    @discardableResult
    mutating func transition(_ phase: Phase, for id: UUID) -> Bool {
        guard self.id == id else { return false }
        let allowed: Bool
        switch (self.phase, phase) {
        case (.preparing, .ready), (.starting, .recording), (.starting, .recognizing),
             (.recording, .recognizing), (.recognizing, .ready): allowed = true
        default: allowed = self.phase == phase || phase == .failed
        }
        guard allowed else { return false }
        self.phase = phase
        return true
    }

    func accepts(_ id: UUID, in phase: Phase) -> Bool { self.id == id && self.phase == phase }

    func releaseAction() -> ReleaseAction {
        switch phase {
        case .starting, .recording: .stop
        default: .ignore
        }
    }
}

// The adapter owns AX, key posting and the pasteboard, so tests run the whole
// snapshot/paste/receipt/restore flow without real input.
protocol DictationPasteAccess: Sendable {
    associatedtype Snapshot: Sendable
    var changeCount: Int { get }
    func snapshot() -> Snapshot
    func restore(_ snapshot: Snapshot, ifUnchangedSince mark: Int)
    // The process holding keyboard focus now, or nil when nothing may receive
    // dictation (no focused process, or a secure text field).
    func destination() -> pid_t?
    func paste(_ text: String, to pid: pid_t, ifUnchangedSince mark: Int) -> DictationPaste?
}

// Text goes wherever the cursor is when recognition finishes, in any app. The
// destination's read of the promised clipboard string is the delivery proof:
// AX cannot see into custom renderers, and a fixed wait restored the clipboard
// before a busy app read it, so the app pasted the user's older clipboard.
struct DictationDelivery<Access: DictationPasteAccess> {
    enum Outcome: Equatable { case delivered, retained }
    static var readDeadline: Duration { .seconds(3) }
    // Hold our clipboard briefly after the read: an app may read it more than once.
    static var holdAfterRead: Duration { .milliseconds(300) }
    static var minimumHold: Duration { .milliseconds(700) }
    static var step: Duration { .milliseconds(50) }

    let access: Access
    var pause: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    func insert(_ text: String) async throws -> Outcome {
        try Task.checkCancellation()
        guard let pid = access.destination() else {
            deliveryLog.notice("Dictation has no destination: no focused process or a secure field")
            return .retained
        }
        let before = access.changeCount
        let original = access.snapshot()
        guard let paste = access.paste(text, to: pid, ifUnchangedSince: before) else {
            deliveryLog.notice("Dictation paste skipped: the clipboard changed before writing")
            return .retained
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
        deliveryLog.notice("Dictation paste to pid \(pid) read \(readAt != nil) after \(latency) ms")
        return readAt == nil ? .retained : .delivered
    }
}

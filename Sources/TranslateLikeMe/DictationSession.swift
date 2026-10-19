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

struct DictationDelivery<Access: SelectionAccess> {
    enum Outcome: Equatable { case confirmed, dispatched, retained }
    let access: Access
    var requiresTextConfirmation = true
    var pause: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    func insert(_ text: String, into target: Access.Target?) async throws -> Outcome {
        try Task.checkCancellation()
        guard let target, access.isCurrent(target) else { return .retained }
        let before = access.changeCount
        let original = access.snapshot()
        guard let attempt = access.paste(text, into: target, ifUnchangedSince: before) else { return .retained }
        // A newer clipboard copy always wins, including when cancellation happens
        // while waiting for the target to consume the paste.
        defer { access.restore(original, ifUnchangedSince: attempt.changeCount) }
        guard attempt.posted else { return .retained }
        await pause(.milliseconds(120))
        try Task.checkCancellation()
        let landed = requiresTextConfirmation && access.replacementLanded(text, in: target)
        await pause(.milliseconds(600))
        try Task.checkCancellation()
        if !requiresTextConfirmation {
            let unchanged = access.isCurrent(target)
            deliveryLog.notice("Dictation paste dispatched without AX text confirmation, window unchanged \(unchanged)")
            return unchanged ? .dispatched : .retained
        }
        // Rich editors may update AX after the first check. Recheck before
        // restoring our clipboard write, without posting another paste.
        let confirmed = landed || access.replacementLanded(text, in: target)
        deliveryLog.notice("Dictation paste confirmed \(confirmed), initial check \(landed)")
        return confirmed ? .confirmed : .retained
    }
}

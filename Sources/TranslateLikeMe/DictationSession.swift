import Foundation

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

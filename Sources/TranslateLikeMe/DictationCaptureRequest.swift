import Foundation

// The lock publishes the sink and serializes release with the hardware-start
// decision. No engine or audio buffer crosses from the worker to MainActor.
final class DictationCaptureRequest: @unchecked Sendable {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tlm-dictation-\(UUID().uuidString).wav")
    private let lock = NSLock()
    private var accepting = true
    private var audio: DictationAudioFile?
    private var error: Error?

    var sink: DictationAudioFile? { lock.withLock { audio } }
    var failure: Error? { lock.withLock { error } }
    var isActive: Bool { lock.withLock { accepting } }
    func publish(_ sink: DictationAudioFile) { lock.withLock { audio = sink } }
    func fail(_ error: Error) { lock.withLock { self.error = error } }
    func end() { lock.withLock { accepting = false } }

    func startWhileHeld(_ start: () throws -> Void) throws {
        try lock.withLock {
            guard accepting else { throw CancellationError() }
            try start()
        }
    }
}

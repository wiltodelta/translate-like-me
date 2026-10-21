import Foundation

// The lock publishes the sink and release state, never a hardware operation.
// No engine or audio buffer crosses from the worker to MainActor.
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

    func startIfActive(_ start: () throws -> Void) throws {
        guard isActive else { throw CancellationError() }
        try start()
    }
}

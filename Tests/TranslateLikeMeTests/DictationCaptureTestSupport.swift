import AVFoundation
import CoreAudio
import XCTest
@testable import TranslateLikeMe

// Capture fixtures stay on the worker queue and never open real audio devices.
final class SyntheticCaptureGraph: DictationInputGraph {
    var format: AVAudioFormat?
    var isRunning = false
    private let onStart: (SyntheticCaptureGraph) throws -> Void

    init(rate: Double, channels: UInt32 = 1, start: @escaping (SyntheticCaptureGraph) throws -> Void) {
        format = HALDictationInputGraph.makePCMFormat(rate: rate, channels: channels)
        onStart = start
    }

    func prepare() throws {}
    func start() throws { isRunning = true; try onStart(self) }
    func stop() { isRunning = false }
    func shutdown() { stop() }
    func deliver(to relay: DictationTapRelay, sample: Float = 0.25) throws {
        let format = try XCTUnwrap(format)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<160 { channels[channel][frame] = sample }
        }
        relay.receive(nil, frames: buffer.frameLength, audio: buffer.audioBufferList)
    }
}

struct UnavailableCaptureOutput: DictationOutputControl {
    func defaultOutput() -> AudioObjectID? { nil }
    func isMuted(_ device: AudioObjectID) -> Bool? { nil }
    func setMuted(_ device: AudioObjectID, _ muted: Bool) -> Bool { false }
    func uid(of device: AudioObjectID) -> String? { nil }
    func device(uid: String) -> AudioObjectID? { nil }
}

final class RouteTestObservation: DictationInputWatching {
    private let onStop: () -> Void
    init(stop: @escaping () -> Void = {}) { onStop = stop }
    func watch(_ route: DictationInputRoute?) {}
    func stop() { onStop() }
}

@MainActor
final class ControlledDictationEngine: DictationRecognizing {
    var loaded = false
    var transcript = ""
    var recognitionError: DictationError?
    var blockNextPreparation = false
    var failNextPreparation = false
    var preparations: [Bool] = []
    var models: [DictationModel] = []
    private(set) var loadedModel: DictationModel?
    var transcribed: [URL] = []
    private var pending: CheckedContinuation<Void, Never>?
    private var preparationObserver: CheckedContinuation<Void, Never>?
    private var unloadObserver: CheckedContinuation<Void, Never>?
    private var unloaded = false

    func prepare(model: DictationModel, download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        loaded = false
        unloaded = false
        preparations.append(download)
        models.append(model)
        if blockNextPreparation {
            blockNextPreparation = false
            await withCheckedContinuation { pending = $0
                preparationObserver?.resume()
                preparationObserver = nil
            }
        }
        try Task.checkCancellation()
        if failNextPreparation {
            failNextPreparation = false
            throw DictationError.notReady
        }
        loaded = true
        loadedModel = model
    }

    func transcribe(_ audio: URL) async throws -> String {
        XCTAssertTrue(loaded)
        transcribed.append(audio)
        if let recognitionError { throw recognitionError }
        return transcript
    }

    func unload() async {
        loaded = false
        loadedModel = nil
        unloaded = true
        unloadObserver?.resume()
        unloadObserver = nil
    }

    func waitForUnload() async {
        if !unloaded { await withCheckedContinuation { unloadObserver = $0 } }
    }

    func waitForPreparation() async {
        if pending == nil { await withCheckedContinuation { preparationObserver = $0 } }
    }

    func waitForPreparation(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while pending == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return pending != nil
    }

    func finishPreparation() {
        pending?.resume()
        pending = nil
    }
}

@MainActor
final class ControlledDictationRecorder: DictationRecording {
    var onEnd: ((Bool) -> Void)?
    let level = 0.5
    var isListening = true
    var trailingQuiet: TimeInterval = 0
    let audio = URL(fileURLWithPath: "/synthetic-dictation.wav")
    var permissions = 0
    var permitted = true
    var warmUps: [Bool] = []
    var inputs: [String?] = []
    var starts = 0
    var stops = 0
    var hasAudio = false
    var startError: DictationError?
    var blockDrain = false
    private var drain: CheckedContinuation<URL, Error>?
    private var drainObserver: CheckedContinuation<Void, Never>?

    func requestPermission() async -> Bool { permissions += 1; return permitted }
    func useInput(_ uid: String?) { inputs.append(uid) }
    func warmUp(rebuild: Bool) { warmUps.append(rebuild) }
    func coolDown() {}
    func start() throws {
        starts += 1
        hasAudio = true
        if let startError { throw startError }
    }
    func stop() throws -> Task<URL, Error> {
        stops += 1
        return Task {
            if blockDrain {
                return try await withCheckedThrowingContinuation { continuation in
                    drain = continuation
                    drainObserver?.resume()
                    drainObserver = nil
                }
            }
            return audio
        }
    }
    func waitForDrain() async {
        if drain == nil { await withCheckedContinuation { drainObserver = $0 } }
    }
    func finishDrain() { drain?.resume(returning: audio); drain = nil }
    func discard() { hasAudio = false }
    func shutdown() { discard() }
}

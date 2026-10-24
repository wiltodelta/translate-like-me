import AVFoundation
import CoreAudio
import Foundation
import os

// Confined to the capture queue, including configuration callbacks and teardown.
protocol DictationInputGraph: AnyObject {
    var format: AVAudioFormat { get }
    var isRunning: Bool { get }
    func prepare()
    func start() throws
    func stop()
    func shutdown()
}

final class AVDictationInputGraph: DictationInputGraph {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    var format: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }
    var isRunning: Bool { engine.isRunning }

    init(device: AudioDeviceID?, followsSystem: Bool, relay: DictationTapRelay,
         changed: @escaping @Sendable () -> Void) throws {
        let input = engine.inputNode
        if let device, !followsSystem { try Self.bind(input, to: device) }
        guard Self.isUsable(format) else { throw DictationError.microphone }
        // nil follows the current hardware format; a stale explicit format can
        // raise an Objective-C exception while Bluetooth switches profiles.
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { @Sendable buffer, time in
            relay.deliver(buffer, at: time)
        }
        guard Self.isUsable(format) else {
            input.removeTap(onBus: 0)
            throw DictationError.microphone
        }
        let sink = AVAudioSinkNode { @Sendable _, _, audio in
            relay.hear(audio)
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: nil)
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in changed() }
    }

    func prepare() { engine.prepare() }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }
    func shutdown() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    // Binds the input before its format is read or a tap installed.
    private static func bind(_ input: AVAudioInputNode, to device: AudioDeviceID) throws {
        var device = device
        guard let unit = input.audioUnit else { throw DictationError.microphone }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            Logger.app("dictation").error("""
                Dictation could not select the chosen microphone: \(status, privacy: .public)
                """)
            throw DictationError.microphone
        }
        Logger.app("dictation").notice("Dictation input bound to the chosen microphone")
    }

    private static func isUsable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }
}

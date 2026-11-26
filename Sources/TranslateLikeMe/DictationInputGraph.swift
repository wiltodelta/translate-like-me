import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import Synchronization
import os

private let graphLog = Logger.app("dictation")

// Confined to the capture queue, including configuration callbacks and teardown.
protocol DictationInputGraph: AnyObject {
    var format: AVAudioFormat? { get }
    var isRunning: Bool { get }
    func prepare() throws
    func start() throws
    func stop()
    func shutdown()
}

// Pre-allocated real-time render state for an input-only AUHAL. Owned via
// Unmanaged until after AudioComponentInstanceDispose so real-time callbacks
// never allocate, lock or perform ARC operations.
final class HALRenderContext: @unchecked Sendable {
    typealias RenderSlice = (
        UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        UnsafePointer<AudioTimeStamp>,
        UInt32,
        UInt32,
        UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus

    private let unit: AudioUnit?
    private let customRender: RenderSlice?
    let configuredFormat: AVAudioFormat
    let relay: DictationTapRelay
    let channels: Int
    let maxFrames: UInt32
    private let samples: UnsafeMutablePointer<Float>
    private let bufferList: UnsafeMutableAudioBufferListPointer
    let wantsRunning = Atomic(false)
    let changed: @Sendable () -> Void

    init(unit: AudioUnit?, configuredFormat: AVAudioFormat, maxFrames: UInt32,
         relay: DictationTapRelay, changed: @escaping @Sendable () -> Void,
         customRender: RenderSlice? = nil) {
        let channels = max(1, Int(configuredFormat.channelCount))
        let safeFrames = max(1, maxFrames)
        let sampleCount = channels * Int(safeFrames)
        self.unit = unit
        self.customRender = customRender
        self.configuredFormat = configuredFormat
        self.relay = relay
        self.channels = channels
        self.maxFrames = safeFrames
        samples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        samples.initialize(repeating: 0, count: sampleCount)
        bufferList = AudioBufferList.allocate(maximumBuffers: channels)
        self.changed = changed
    }

    deinit {
        let sampleCount = channels * Int(maxFrames)
        free(bufferList.unsafeMutablePointer)
        samples.deinitialize(count: sampleCount)
        samples.deallocate()
    }

    func render(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                timeStamp: UnsafePointer<AudioTimeStamp>,
                busNumber: UInt32, frameCount: UInt32) -> OSStatus {
        guard frameCount > 0, frameCount <= maxFrames else {
            return kAudioUnitErr_TooManyFramesToProcess
        }
        let byteSize = frameCount * UInt32(MemoryLayout<Float>.size)
        for channel in 0..<channels {
            bufferList[channel].mNumberChannels = 1
            bufferList[channel].mDataByteSize = byteSize
            bufferList[channel].mData = UnsafeMutableRawPointer(samples + channel * Int(maxFrames))
        }
        let listPointer = bufferList.unsafeMutablePointer
        let status: OSStatus
        if let customRender {
            status = customRender(actionFlags, timeStamp, busNumber, frameCount, listPointer)
        } else if let unit {
            status = AudioUnitRender(unit, actionFlags, timeStamp, busNumber, frameCount, listPointer)
        } else {
            return kAudioUnitErr_Uninitialized
        }
        guard status == noErr else { return status }
        relay.receive(timeStamp, frames: frameCount, audio: listPointer)
        return noErr
    }
}

private let halInputCallback: AURenderCallback = { refCon, actionFlags, timeStamp, busNumber, frameCount, _ in
    let context = Unmanaged<HALRenderContext>.fromOpaque(refCon).takeUnretainedValue()
    return context.render(actionFlags: actionFlags, timeStamp: timeStamp,
                          busNumber: busNumber, frameCount: frameCount)
}

private let halPropertyListener: AudioUnitPropertyListenerProc = { refCon, unit, propertyID, _, _ in
    let context = Unmanaged<HALRenderContext>.fromOpaque(refCon).takeUnretainedValue()
    if propertyID == kAudioOutputUnitProperty_IsRunning {
        guard context.wantsRunning.load(ordering: .acquiring),
              !HALDictationInputGraph.queryIsRunning(unit) else {
            return
        }
        context.wantsRunning.store(false, ordering: .releasing)
    } else if propertyID == kAudioUnitProperty_StreamFormat {
        let configured = context.configuredFormat
        if let shape = HALDictationInputGraph.hardwareStreamShape(of: unit),
           shape.rate == configured.sampleRate,
           shape.channels == configured.channelCount {
            return
        }
    }
    context.changed()
}

// Input-only AUHAL (TN2091): output bus 0 is disabled before binding the target
// input device, so Core Audio never builds a default-device aggregate with the
// system output or touches a Bluetooth headset while a local mic is used.
final class HALDictationInputGraph: DictationInputGraph {
    private static let minimumSliceFrames: UInt32 = 8_192

    private var unit: AudioUnit?
    private var contextRef: Unmanaged<HALRenderContext>?
    private var initialized = false

    var format: AVAudioFormat? {
        guard let unit, let context = contextRef?.takeUnretainedValue(),
              let shape = Self.hardwareStreamShape(of: unit) else {
            return nil
        }
        let configured = context.configuredFormat
        if shape.rate == configured.sampleRate, shape.channels == configured.channelCount {
            return configured
        }
        return Self.makePCMFormat(rate: shape.rate, channels: shape.channels)
    }

    var isRunning: Bool {
        guard let unit else { return false }
        return Self.queryIsRunning(unit)
    }

    init(device: AudioDeviceID, relay: DictationTapRelay,
         changed: @escaping @Sendable () -> Void) throws {
        let unit = try Self.makeUnit()
        var succeeded = false
        defer {
            if !succeeded { _ = AudioComponentInstanceDispose(unit) }
        }
        try Self.configureInputOnly(unit, device: device)
        guard let shape = Self.hardwareStreamShape(of: unit),
              let initialFormat = Self.makePCMFormat(rate: shape.rate, channels: shape.channels) else {
            throw DictationError.microphone
        }
        try Self.setClientFormat(initialFormat, on: unit)
        let maxFrames = Self.configureMaxFrames(unit)
        let context = HALRenderContext(unit: unit, configuredFormat: initialFormat,
                                       maxFrames: maxFrames, relay: relay, changed: changed)
        let contextRef = Unmanaged.passRetained(context)
        do {
            try Self.attachCallbacks(unit, opaque: contextRef.toOpaque())
        } catch {
            contextRef.release()
            throw error
        }
        self.unit = unit
        self.contextRef = contextRef
        succeeded = true
    }

    deinit { shutdown() }

    func prepare() throws {
        guard let unit else { throw DictationError.microphone }
        guard !initialized else { return }
        let status = AudioUnitInitialize(unit)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        initialized = true
    }

    func start() throws {
        guard let unit, let context = contextRef?.takeUnretainedValue() else {
            throw DictationError.microphone
        }
        if !initialized { try prepare() }
        context.wantsRunning.store(true, ordering: .releasing)
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            context.wantsRunning.store(false, ordering: .releasing)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func stop() {
        guard let unit else { return }
        contextRef?.takeUnretainedValue().wantsRunning.store(false, ordering: .releasing)
        _ = AudioOutputUnitStop(unit)
    }

    func shutdown() {
        guard let unit, let contextRef else { return }
        self.unit = nil
        self.contextRef = nil
        initialized = false
        let opaque = contextRef.toOpaque()
        contextRef.takeUnretainedValue().wantsRunning.store(false, ordering: .releasing)
        Self.detachCallbacks(unit, opaque: opaque)
        _ = AudioUnitUninitialize(unit)
        _ = AudioComponentInstanceDispose(unit)
        contextRef.release()
    }
}

extension HALDictationInputGraph {
    static func makePCMFormat(rate: Double, channels: UInt32) -> AVAudioFormat? {
        guard rate.isFinite, rate > 0, channels > 0 else { return nil }
        if channels <= 2, let standard = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels) {
            return standard
        }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) else {
            return nil
        }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                             interleaved: false, channelLayout: layout)
    }

    fileprivate static func hardwareStreamShape(of unit: AudioUnit) -> (rate: Double, channels: UInt32)? {
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                   &description, &size) == noErr,
              description.mSampleRate.isFinite, description.mSampleRate > 0,
              description.mChannelsPerFrame > 0 else {
            return nil
        }
        return (description.mSampleRate, description.mChannelsPerFrame)
    }

    fileprivate static func queryIsRunning(_ unit: AudioUnit) -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0,
                                   &running, &size) == noErr else {
            return false
        }
        return running != 0
    }

    private static func makeUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw DictationError.microphone
        }
        var created: AudioUnit?
        guard AudioComponentInstanceNew(component, &created) == noErr, let unit = created else {
            throw DictationError.microphone
        }
        return unit
    }

    // Disable output first so setting CurrentDevice to an input-only microphone
    // never asks Core Audio for output channels or a default-device aggregate.
    private static func configureInputOnly(_ unit: AudioUnit, device: AudioDeviceID) throws {
        var disabled: UInt32 = 0
        var enabled: UInt32 = 1
        let flagSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                   &disabled, flagSize) == noErr,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                   &enabled, flagSize) == noErr else {
            throw DictationError.microphone
        }
        var device = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            graphLog.error("Dictation could not select the input microphone: \(status, privacy: .public)")
            throw DictationError.microphone
        }
        graphLog.notice("Dictation input bound to the selected microphone")
    }

    private static func configureMaxFrames(_ unit: AudioUnit) -> UInt32 {
        var unitMaxFrames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                 &unitMaxFrames, &size)
        var maxFrames = max(minimumSliceFrames, unitMaxFrames)
        _ = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                 &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        return maxFrames
    }

    private static func setClientFormat(_ format: AVAudioFormat, on unit: AudioUnit) throws {
        var clientFormat = format.streamDescription.pointee
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                   &clientFormat, formatSize) == noErr else {
            throw DictationError.microphone
        }
    }

    private static func attachCallbacks(_ unit: AudioUnit, opaque: UnsafeMutableRawPointer) throws {
        var callback = AURenderCallbackStruct(inputProc: halInputCallback, inputProcRefCon: opaque)
        let callbackSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                   &callback, callbackSize) == noErr,
              AudioUnitAddPropertyListener(unit, kAudioUnitProperty_StreamFormat,
                                           halPropertyListener, opaque) == noErr,
              AudioUnitAddPropertyListener(unit, kAudioOutputUnitProperty_IsRunning,
                                           halPropertyListener, opaque) == noErr else {
            detachCallbacks(unit, opaque: opaque)
            throw DictationError.microphone
        }
    }

    private static func detachCallbacks(_ unit: AudioUnit, opaque: UnsafeMutableRawPointer) {
        AudioUnitRemovePropertyListenerWithUserData(unit, kAudioUnitProperty_StreamFormat,
                                                    halPropertyListener, opaque)
        AudioUnitRemovePropertyListenerWithUserData(unit, kAudioOutputUnitProperty_IsRunning,
                                                    halPropertyListener, opaque)
        _ = AudioOutputUnitStop(unit)
        var empty = AURenderCallbackStruct(inputProc: nil, inputProcRefCon: nil)
        _ = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                 &empty, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    }
}

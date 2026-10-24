import CoreAudio
import Foundation

// Snapshot identity and native properties, not just a reusable numeric ID.
struct DictationInputRoute: Equatable, Sendable {
    let device: AudioDeviceID
    let uid: String
    var channels: UInt32 = 1
    var sampleRate: Double?
    var dataSource: UInt32?

    static func resolve(_ preferred: String?, device: (String) -> AudioDeviceID? = audioDevice(uid:),
                        system: () -> AudioDeviceID? = {
                            defaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice)
                        },
                        snapshot: (AudioDeviceID) -> Self? = read) -> Self? {
        if let preferred, let id = device(preferred), let route = snapshot(id), route.uid == preferred { return route }
        return system().flatMap(snapshot)
    }

    static func read(_ device: AudioDeviceID) -> Self? {
        guard value(device, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) == 1,
              let uid = audioDeviceUID(device), let channels = channelCount(device), channels > 0 else { return nil }
        var route = Self(device: device, uid: uid, channels: channels)
        if let rate = value(device, kAudioDevicePropertyNominalSampleRate, initial: 0.0), rate.isFinite, rate > 0 {
            route.sampleRate = rate
        }
        route.dataSource = value(device, kAudioDevicePropertyDataSource,
                                 scope: kAudioObjectPropertyScopeInput, initial: UInt32(0))
        return route
    }

    private static func channelCount(_ device: AudioDeviceID) -> UInt32? {
        var address = audioAddress(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return nil }
        let capacity = Int(size)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: capacity,
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr,
              size >= MemoryLayout<AudioBufferList>.size, size <= capacity else { return nil }
        let list = memory.assumingMemoryBound(to: AudioBufferList.self)
        let maximum = 1 + (Int(size) - MemoryLayout<AudioBufferList>.size) / MemoryLayout<AudioBuffer>.stride
        guard list.pointee.mNumberBuffers <= maximum else { return nil }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
    }

    private static func value<T: BitwiseCopyable>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                                  initial: T) -> T? {
        var address = audioAddress(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<T>.size else { return nil }
        return value
    }
}

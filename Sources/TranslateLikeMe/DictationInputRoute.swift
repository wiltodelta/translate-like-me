import CoreAudio
import Foundation

// Snapshot identity and native properties, not just a reusable numeric ID.
struct DictationInputRoute: Equatable, Sendable {
    let device: AudioDeviceID
    let uid: String
    var channels: UInt32 = 1
    var sampleRate: Double?
    var dataSource: UInt32?
    var transport: AudioInputTransport = .unknown
    var followsSystem = true

    // Normalizes selection provenance so synthesized Equatable compares hardware identity.
    var hardware: Self {
        var copy = self
        copy.followsSystem = true
        return copy
    }

    static func resolve(_ preferred: String?, device: (String) -> AudioDeviceID? = audioDevice(uid:),
                        system: () -> AudioDeviceID? = {
                            defaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice)
                        },
                        candidates: () -> [AudioDeviceID] = visibleAudioDevices,
                        snapshot: (AudioDeviceID) -> Self? = read) -> Self? {
        if let preferred, let id = device(preferred), var route = snapshot(id), route.uid == preferred {
            route.followsSystem = false
            return route
        }
        let systemID = system()
        let systemRoute = systemID.flatMap(snapshot)
        if let systemRoute, systemRoute.transport != .bluetooth {
            return systemRoute
        }
        if var bypass = nonBluetoothFallback(from: candidates(), excluding: systemID, snapshot: snapshot) {
            bypass.followsSystem = false
            return bypass
        }
        return systemRoute
    }

    static func read(_ device: AudioDeviceID) -> Self? {
        guard audioPropertyValue(device, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) == 1,
              let channels = channelCount(device), channels > 0,
              let uid = audioDeviceUID(device) else { return nil }
        var route = Self(device: device, uid: uid, channels: channels, transport: audioInputTransport(device))
        if let rate = audioPropertyValue(device, kAudioDevicePropertyNominalSampleRate, initial: 0.0),
            rate.isFinite, rate > 0 {
            route.sampleRate = rate
        }
        route.dataSource = audioPropertyValue(device, kAudioDevicePropertyDataSource,
                                              scope: kAudioObjectPropertyScopeInput, initial: UInt32(0))
        return route
    }

    // Physical local microphones beat a Bluetooth system input: built-in wins on
    // laptops and iMacs; wired interfaces cover Mac mini/Studio and closed-lid
    // MacBooks without waking Continuity iPhone mics or silent loopbacks.
    private static func nonBluetoothFallback(from candidates: [AudioDeviceID], excluding excluded: AudioDeviceID?,
                                             snapshot: (AudioDeviceID) -> Self?) -> Self? {
        var wiredFallback: Self?
        for candidate in candidates where candidate != excluded {
            guard let route = snapshot(candidate) else { continue }
            switch route.transport {
            case .builtIn: return route
            case .usb, .thunderbolt, .pci, .fireWire:
                if wiredFallback == nil { wiredFallback = route }
            default: break
            }
        }
        return wiredFallback
    }

    private static func channelCount(_ device: AudioDeviceID) -> UInt32? {
        var address = audioAddress(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return nil }
        let capacity = Int(size)
        return withUnsafeTemporaryAllocation(byteCount: capacity,
                                             alignment: MemoryLayout<AudioBufferList>.alignment) { buffer in
            guard let memory = buffer.baseAddress,
                  AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr,
                  size >= MemoryLayout<AudioBufferList>.size, size <= capacity else { return nil }
            let list = memory.assumingMemoryBound(to: AudioBufferList.self)
            let maximum = 1 + (Int(size) - MemoryLayout<AudioBufferList>.size) / MemoryLayout<AudioBuffer>.stride
            guard list.pointee.mNumberBuffers <= maximum else { return nil }
            return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
        }
    }
}

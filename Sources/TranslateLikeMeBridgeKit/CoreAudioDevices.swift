import CoreAudio

// Core Audio device lookups shared by dictation's input choice and output mute.

public func audioAddress(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

public func audioPropertyValue<T: BitwiseCopyable>(
    _ device: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    initial: T
) -> T? {
    var address = audioAddress(selector, scope)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    guard AudioObjectHasProperty(device, &address),
          AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
          size == MemoryLayout<T>.size else { return nil }
    return value
}

// The system's current default input or output device.
public func defaultAudioDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
    guard let device = audioPropertyValue(AudioObjectID(kAudioObjectSystemObject), selector,
                                          initial: AudioObjectID(kAudioObjectUnknown)),
          device != kAudioObjectUnknown else { return nil }
    return device
}

public func audioDeviceName(_ device: AudioObjectID) -> String? {
    audioDeviceString(device, kAudioObjectPropertyName)
}

public func audioDeviceUID(_ device: AudioObjectID) -> String? {
    audioDeviceString(device, kAudioDevicePropertyDeviceUID)
}

public enum AudioInputTransport: String, Equatable, Sendable {
    case builtIn = "built-in"
    case bluetooth
    case usb
    case thunderbolt
    case pci
    case fireWire = "firewire"
    case virtual
    case aggregate
    case continuity
    case other
    case unknown
}

private let audioTransportByType: [UInt32: AudioInputTransport] = [
    kAudioDeviceTransportTypeBuiltIn: .builtIn,
    kAudioDeviceTransportTypeBluetooth: .bluetooth,
    kAudioDeviceTransportTypeBluetoothLE: .bluetooth,
    kAudioDeviceTransportTypeUSB: .usb,
    kAudioDeviceTransportTypeThunderbolt: .thunderbolt,
    kAudioDeviceTransportTypePCI: .pci,
    kAudioDeviceTransportTypeFireWire: .fireWire,
    kAudioDeviceTransportTypeVirtual: .virtual,
    kAudioDeviceTransportTypeAggregate: .aggregate,
    kAudioDeviceTransportTypeAutoAggregate: .aggregate,
    kAudioDeviceTransportTypeContinuityCaptureWired: .continuity,
    kAudioDeviceTransportTypeContinuityCaptureWireless: .continuity,
]

// Transport metadata does not open the input or change its format.
public func audioInputTransport(_ device: AudioObjectID) -> AudioInputTransport {
    guard let raw = audioPropertyValue(device, kAudioDevicePropertyTransportType, initial: UInt32(0)) else {
        return .unknown
    }
    return audioTransportByType[raw] ?? .other
}

// Non-hidden Core Audio devices; engines and other apps create private aggregates.
public func visibleAudioDevices() -> [AudioDeviceID] {
    var address = audioAddress(kAudioHardwarePropertyDevices)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
    let count = min(devices.count, Int(size) / MemoryLayout<AudioDeviceID>.size)
    return devices.prefix(count).filter { device in
        device != kAudioObjectUnknown
            && audioPropertyValue(device, kAudioDevicePropertyIsHidden, initial: UInt32(0)) != 1
    }
}

private func audioDeviceString(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = audioAddress(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
          let value else { return nil }
    return value.takeRetainedValue() as String
}

// The connected device with this UID; nil once it is disconnected.
public func audioDevice(uid: String) -> AudioObjectID? {
    var address = audioAddress(kAudioHardwarePropertyTranslateUIDToDevice)
    var uid = uid as CFString
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafeMutablePointer(to: &uid) { pointer in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                   UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
    }
    guard status == noErr, device != kAudioObjectUnknown else { return nil }
    return device
}

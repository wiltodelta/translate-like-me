import CoreAudio

// Core Audio device lookups shared by dictation's input choice and output mute.

func audioAddress(_ selector: AudioObjectPropertySelector,
                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

// The system's current default input or output device.
func defaultAudioDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
    var address = audioAddress(selector)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                     &size, &device) == noErr,
          device != kAudioObjectUnknown else { return nil }
    return device
}

func audioDeviceName(_ device: AudioObjectID) -> String? {
    audioDeviceString(device, kAudioObjectPropertyName)
}

func audioDeviceUID(_ device: AudioObjectID) -> String? {
    audioDeviceString(device, kAudioDevicePropertyDeviceUID)
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
func audioDevice(uid: String) -> AudioObjectID? {
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

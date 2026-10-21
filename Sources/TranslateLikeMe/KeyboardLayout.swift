import Carbon.HIToolbox
import CoreGraphics

// Command shortcuts follow the user's ASCII-capable layout, so the fixed ANSI
// key codes for C and V send Cmd+J and Cmd+K under Dvorak, where C and V sit on
// the I and . keys. Non-Latin layouts such as Russian match shortcuts through
// that same ASCII-capable layout.
enum KeyboardLayout {
    // The ANSI codes stand in when the layout cannot be read.
    @MainActor static var copyKey: CGKeyCode { keyCode(typing: "c", fallback: CGKeyCode(kVK_ANSI_C)) }
    @MainActor static var pasteKey: CGKeyCode { keyCode(typing: "v", fallback: CGKeyCode(kVK_ANSI_V)) }

    // Text Input Sources must be read on the main thread.
    @MainActor
    static func keyCode(typing character: Character, fallback: CGKeyCode) -> CGKeyCode {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let code = keyCode(typing: character, in: source) else { return fallback }
        return code
    }

    @MainActor
    static func keyCode(typing character: Character, in source: TISInputSource) -> CGKeyCode? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let target = String(character)
        return data.withUnsafeBytes { bytes -> CGKeyCode? in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            let command = UInt32((cmdKey >> 8) & 0xFF)
            let keyboard = UInt32(LMGetKbdType())
            var characters = [UniChar](repeating: 0, count: 4)
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), command, keyboard,
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeys, characters.count, &length, &characters)
                if status == noErr, String(utf16CodeUnits: characters, count: length) == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}

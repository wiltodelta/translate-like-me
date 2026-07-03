import AppKit
import Carbon

// Helpers to translate between NSEvent modifier flags / key codes and the
// Carbon values RegisterEventHotKey wants, plus a human-readable display string.
enum Shortcut {
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

    // "⌘⌥T" style label for the current binding.
    static func display(keyCode: Int, modifiers: Int) -> String {
        let mods = UInt32(modifiers)
        var result = ""
        if mods & UInt32(controlKey) != 0 { result += "⌃" }
        if mods & UInt32(optionKey) != 0 { result += "⌥" }
        if mods & UInt32(shiftKey) != 0 { result += "⇧" }
        if mods & UInt32(cmdKey) != 0 { result += "⌘" }
        result += keyName(keyCode)
        return result
    }

    // US-layout key codes (these match NSEvent.keyCode and Carbon virtual keys).
    private static let names: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        28: "8", 29: "0", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
        45: "N", 46: "M", 49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
        // Punctuation
        27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        // Arrows
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    static func keyName(_ code: Int) -> String {
        names[code] ?? "Key \(code)"
    }
}

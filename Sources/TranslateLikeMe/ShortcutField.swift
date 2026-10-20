import SwiftUI
import AppKit
import Carbon

// A click-to-record shortcut control. Click it, press a key combo (must include
// at least one non-shift modifier), and it stores the Carbon key code + modifier
// mask; Delete clears it and Esc cancels. Key SEQUENCES are not supported - the
// first valid press wins and recording stops. A combo `usedBy` names (another
// pair's) is refused, so one shortcut never triggers two translations.
// Dictation requires a standalone left or right Option binding.
struct ShortcutField: View {
    @Binding var combo: KeyCombo?
    let usedBy: (KeyCombo) -> ShortcutOwner?
    // What the shortcut runs: VoiceOver read the bare combo, with nothing
    // saying whose shortcut it was.
    let owner: ShortcutOwner
    var requiresOptionOnly = false

    @State private var recording = false
    @State private var monitor: Any?
    @State private var conflict: ShortcutOwner?
    @State private var leftOption = OptionKeyGesture(keyCode: 58)
    @State private var rightOption = OptionKeyGesture(keyCode: 61)

    private var label: some View {
        Text(recording ? String(localized: "Press keys…")
             : combo.map(Shortcut.display) ?? String(localized: "Record Shortcut"))
            // Monospaced for the glyphs of a recorded combo only, not for prose.
            .font(combo != nil && !recording ? .body.monospaced() : .body)
            // Never truncated: a long second language squeezed "Record Shortcut"
            // to "Record Short…". The bezel's padding gives way instead; a fixed-size
            // button pushed the row past the form's width and hid the ↔.
            .fixedSize()
            .frame(minWidth: 90)
    }

    // macOS 26: a standard bordered button, so the system draws the Liquid Glass
    // control shape; recording switches to the prominent (accent) style. Earlier
    // versions keep the original custom field look.
    @ViewBuilder private var recorderButton: some View {
        if #available(macOS 26.0, *) {
            if recording {
                Button(action: toggle) { label }.buttonStyle(.borderedProminent)
            } else {
                Button(action: toggle) { label }.buttonStyle(.bordered)
            }
        } else {
            Button(action: toggle) {
                label
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(recording ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlColor),
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(recording ? Color.accentColor : Color(nsColor: .separatorColor),
                                    lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var recordingHint: String {
        requiresOptionOnly ? String(localized: "Press left or right Option. Delete clears, Esc cancels.")
            : String(localized: "Needs ⌘, ⌥, or ⌃. Delete clears, Esc cancels.")
    }

    var body: some View {
        // The hint has its own row below the button while recording, instead of
        // competing for the row's narrow trailing width.
        VStack(alignment: .trailing, spacing: 4) {
            recorderButton
                .accessibilityLabel(owner.label)
                .accessibilityValue(recording ? String(localized: "Recording", comment: "A shortcut being recorded")
                                    : combo.map(Shortcut.display) ?? String(localized: "None", comment: "No shortcut"))
            if recording {
                Text(conflict?.conflict ?? recordingHint)
                    .font(.caption2)
                    .foregroundStyle(Color.secondaryText)
            }
        }
        .onDisappear { stop() }
    }

    private func toggle() {
        if recording { stop(); return }
        recording = true
        leftOption = OptionKeyGesture(keyCode: 58, initialFlags: NSEvent.modifierFlags)
        rightOption = OptionKeyGesture(keyCode: 61, initialFlags: NSEvent.modifierFlags)
        // The active shortcut is a live global hotkey; pause it so pressing the
        // SAME combo here is delivered to this recorder instead of firing it.
        // This matches how KeyboardShortcuts (the de facto standard library for
        // this on macOS) handles it: pause the global registration while recording.
        HotKeyManager.shared.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: OptionKeyGesture.events) { event in
            if event.type == .flagsChanged {
                let left = leftOption.flagsChanged(keyCode: Int(event.keyCode), flags: event.modifierFlags)
                let right = rightOption.flagsChanged(keyCode: Int(event.keyCode), flags: event.modifierFlags)
                if requiresOptionOnly && (left == .release || right == .release) {
                    accept(KeyCombo(keyCode: left == .release ? 58 : 61, modifiers: Int(optionKey)))
                }
                return event
            }
            leftOption.cancel()
            rightOption.cancel()
            guard event.type == .keyDown else { return event }
            if event.keyCode == 53 { stop(); return nil } // Esc cancels
            if event.keyCode == 51 || event.keyCode == 117 { // Delete, Forward Delete
                combo = nil
                stop()
                return nil
            }
            guard !requiresOptionOnly else { NSSound.beep(); return nil }
            let mods = Shortcut.carbonModifiers(from: event.modifierFlags)
            // Shift alone isn't a usable global-hotkey modifier on macOS (it doesn't
            // reliably work), so require at least one of Cmd/Option/Control too -
            // same validation KeyboardShortcuts applies.
            guard mods & ~UInt32(shiftKey) != 0 else { NSSound.beep(); return nil }
            let recorded = KeyCombo(keyCode: Int(event.keyCode), modifiers: Int(mods))
            accept(recorded)
            return nil
        }
    }

    private func accept(_ recorded: KeyCombo) {
        if let owner = usedBy(recorded) {
            conflict = owner
            NSSound.beep()
        } else {
            combo = recorded
            stop()
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        conflict = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        // Re-arm the global hotkey with the persisted (possibly just recorded) one.
        HotKeyManager.shared.resume()
    }
}

// What a shortcut belongs to. Each case has whole sentences of its own, since
// languages inflect the name differently in each sentence.
enum ShortcutOwner: Equatable {
    case pair(String)
    case preset(String)
    case dictation

    var label: String {
        switch self {
        case .pair(let title): String(localized: "Shortcut for the \(title) pair")
        case .preset(let title): String(localized: "Shortcut for the \(title) preset")
        case .dictation: String(localized: "Dictation shortcut")
        }
    }

    var conflict: String {
        switch self {
        case .pair(let title): String(localized: "Already used by the \(title) pair.")
        case .preset(let title): String(localized: "Already used by the \(title) preset.")
        case .dictation: String(localized: "Already used by Dictation.")
        }
    }
}

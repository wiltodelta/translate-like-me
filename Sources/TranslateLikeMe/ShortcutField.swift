import SwiftUI
import AppKit
import Carbon

// A click-to-record shortcut control. Click it, press a key combo (must include
// at least one non-shift modifier), and it stores the Carbon key code + modifier
// mask; Delete clears it and Esc cancels. Key SEQUENCES are not supported - the
// first valid press wins and recording stops. A combo `usedBy` names (another
// pair's) is refused, so one shortcut never triggers two translations.
struct ShortcutField: View {
    @Binding var combo: KeyCombo?
    let usedBy: (KeyCombo) -> String?

    @State private var recording = false
    @State private var monitor: Any?
    @State private var conflict: String?

    private var label: some View {
        Text(recording ? "Press keys…"
             : combo.map(Shortcut.display) ?? "Record Shortcut")
            .font(combo == nil && !recording ? .body : .body.monospaced())
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

    var body: some View {
        // The hint has its own row below the button while recording, instead of
        // competing for the row's narrow trailing width.
        VStack(alignment: .trailing, spacing: 4) {
            recorderButton
            if recording {
                Text(conflict.map { "Already used by \($0)." } ?? "Needs ⌘, ⌥, or ⌃. Delete clears, Esc cancels.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stop() }
    }

    private func toggle() {
        if recording { stop(); return }
        recording = true
        // The active shortcut is a live global hotkey; pause it so pressing the
        // SAME combo here is delivered to this recorder instead of firing it.
        // This matches how KeyboardShortcuts (the de facto standard library for
        // this on macOS) handles it: pause the global registration while recording.
        HotKeyManager.shared.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // Esc cancels
            if event.keyCode == 51 || event.keyCode == 117 { // Delete, Forward Delete
                combo = nil
                stop()
                return nil
            }
            let mods = Shortcut.carbonModifiers(from: event.modifierFlags)
            // Shift alone isn't a usable global-hotkey modifier on macOS (it doesn't
            // reliably work), so require at least one of Cmd/Option/Control too -
            // same validation KeyboardShortcuts applies.
            guard mods & ~UInt32(shiftKey) != 0 else { NSSound.beep(); return nil }
            let recorded = KeyCombo(keyCode: Int(event.keyCode), modifiers: Int(mods))
            if let owner = usedBy(recorded) {
                conflict = owner
                NSSound.beep()
                return nil
            }
            combo = recorded
            stop()
            return nil
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

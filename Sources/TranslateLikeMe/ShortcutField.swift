import SwiftUI
import AppKit
import Carbon

// A click-to-record shortcut control. Click it, press a key combo (must include
// at least one non-shift modifier, or a function key), and it stores the Carbon
// key code + modifier mask. Esc cancels recording. Key SEQUENCES (e.g. pressing a
// key twice) are not supported - only a single key held with modifier(s) - so the
// first valid press wins and recording stops immediately.
struct ShortcutField: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        // Stacked, not side-by-side: the hint/Reset line has its own row below
        // the button instead of competing for LabeledContent's narrow trailing
        // width, which used to wrap it mid-sentence.
        VStack(alignment: .trailing, spacing: 4) {
            Button(action: toggle) {
                Text(recording ? "Press keys…" : Shortcut.display(keyCode: keyCode, modifiers: modifiers))
                    .font(.body.monospaced())
                    .frame(minWidth: 90)
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

            if recording {
                Text("Needs ⌘, ⌥, or ⌃ (⇧ alone doesn't work). Esc cancels.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if keyCode != Settings.defaultReplaceKeyCode || modifiers != Settings.defaultReplaceModifiers {
                Button("Reset") {
                    stop()
                    keyCode = Settings.defaultReplaceKeyCode
                    modifiers = Settings.defaultReplaceModifiers
                }
                .buttonStyle(.plain)
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
            let mods = Shortcut.carbonModifiers(from: event.modifierFlags)
            // Shift alone isn't a usable global-hotkey modifier on macOS (it doesn't
            // reliably work), so require at least one of Cmd/Option/Control too -
            // same validation KeyboardShortcuts applies.
            let hasRealModifier = mods & ~UInt32(shiftKey) != 0
            guard hasRealModifier else { NSSound.beep(); return nil }
            keyCode = Int(event.keyCode)
            modifiers = Int(mods)
            stop()
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        // Re-arm the global hotkey (still the persisted one until Save is pressed).
        HotKeyManager.shared.resume()
    }
}

import AppKit
import SwiftUI
import TunkEmit

/// Click, press the combination, done. While recording, a local event monitor
/// swallows the keystroke so recording ⌘Q does not quit the app mid-record.
struct HotkeyRecorderView: View {
    @Binding var binding: HotkeySpec
    @State private var recording = false
    @State private var monitor: Any?
    @State private var complaint: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    Text(recording ? "Press keys…" : binding.symbolicDescription)
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .frame(minWidth: 96)
                }
                .buttonStyle(TunkButtonStyle(prominent: recording))
                .help("Set the combination Tunk sends on a double-tap")

                if recording {
                    Text("Esc to cancel")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
            }
            if let complaint {
                Text(complaint)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }
        .tunkAnimation(.tunkSnappy, value: recording, reduceMotion: reduceMotion)
        .tunkAnimation(.tunkSnappy, value: complaint, reduceMotion: reduceMotion)
        .onDisappear(perform: endRecording)
    }

    private func toggle() {
        recording ? endRecording() : beginRecording()
    }

    private func beginRecording() {
        complaint = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            switch event.type {
            case .keyDown:
                if event.keyCode == 53 {                   // Escape
                    endRecording()
                    return nil
                }
                let spec = HotkeySpec(keyCode: event.keyCode, eventModifiers: event.modifierFlags)
                guard spec.hasModifier else {
                    complaint = "Pick something with at least one modifier — a bare key would "
                        + "fire while you type."
                    return nil
                }
                commit(spec)

            case .flagsChanged:
                // A modifier on its own is a legitimate shortcut; VoiceInk takes
                // one. Press it and it lands on the press, not on the release,
                // so the panel reacts the moment the key goes down.
                guard KeyCodes.isModifier(event.keyCode) else { return nil }
                guard isPress(event) else { return nil }
                commit(HotkeySpec(keyCode: event.keyCode, eventModifiers: event.modifierFlags))

            default:
                break
            }
            return nil
        }
    }

    /// `flagsChanged` fires on both press and release. The event carries the
    /// post-change state, so the key is going down exactly when its own flag is
    /// still asserted afterwards.
    private func isPress(_ event: NSEvent) -> Bool {
        guard let role = KeyCodes.modifierRole(for: event.keyCode) else { return false }
        let raw = event.modifierFlags.rawValue
        switch role.modifier {
        case .control:  return raw & NSEvent.ModifierFlags.control.rawValue != 0
        case .option:   return raw & NSEvent.ModifierFlags.option.rawValue != 0
        case .shift:    return raw & NSEvent.ModifierFlags.shift.rawValue != 0
        case .command:  return raw & NSEvent.ModifierFlags.command.rawValue != 0
        case .function: return raw & NSEvent.ModifierFlags.function.rawValue != 0
        default:        return false
        }
    }

    private func commit(_ spec: HotkeySpec) {
        // Right Shift is the user's manual VoiceInk primary. Emitting it would
        // fight the binding Tunk exists to leave alone, so it is refused here
        // rather than silently accepted and mysteriously double-firing later.
        if spec.collidesWithVoiceInkPrimary {
            complaint = "Right Shift is your manual VoiceInk trigger. Tunk sending it too "
                + "would toggle dictation twice. Pick a different combination."
            return
        }
        if spec.isBareModifier {
            complaint = "\(spec.symbolicDescription) works, but a lone modifier is easy to "
                + "hit by accident. A rare combination is safer."
        } else {
            complaint = nil
        }
        binding = spec
        endRecording()
    }

    private func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

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
        // Bare modifiers are allowed. The worry was that a synthesized one would
        // be invisible to a listener watching flagsChanged; measured on this
        // machine it is not — an emitted Right Shift arrives as
        // flagsChanged keyCode=60 flags=0x20020004, with the right-hand device
        // bit set. So this is advice, not a veto.
        if spec.isTypingModifier {
            complaint = "\(spec.symbolicDescription) is also a typing key, so a stray "
                + "double-tap sends a real modifier. Harmless on its own, but a rare "
                + "combination misfires less."
        } else if spec.isBareModifier {
            complaint = "\(spec.symbolicDescription) works. A lone modifier is easier to "
                + "hit by accident than a combination."
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

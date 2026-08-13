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
            guard event.type == .keyDown else { return nil }
            if event.keyCode == 53 {                       // Escape
                endRecording()
                return nil
            }
            let spec = HotkeySpec(keyCode: event.keyCode, eventModifiers: event.modifierFlags)
            guard spec.hasModifier else {
                complaint = "Pick something with at least one modifier — a bare key would "
                    + "fire while you type."
                return nil
            }
            binding = spec
            complaint = nil
            endRecording()
            return nil
        }
    }

    private func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

import AppKit
import SwiftUI
import TunkCore
import TunkEmit

final class PanelModel: ObservableObject {
    @Published var showCalibration = false
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engine: Engine
    @ObservedObject var panel: PanelModel
    @StateObject private var monitor = TapMonitorModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAdvanced = false
    @State private var emitTestResult: String?

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 14) {
                if !engine.permissions.ready { permissionCard }
                statusCard
                monitorCard
                detectionCard
                hotkeyCard
                calibrationCard
                footnote
            }
            .padding(Metrics.panelPadding)
        }
        .frame(width: 452)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { monitor.start(engine: engine) }
        .onDisappear { monitor.stop() }
        .sheet(isPresented: $panel.showCalibration) {
            CalibrationView(engine: engine) { panel.showCalibration = false }
        }
    }

    // MARK: - permissions

    private var permissionCard: some View {
        Card(title: "Tunk is not armed",
             caption: "Detection stays off until both permissions are granted. Without them "
                    + "Tunk cannot see your typing, and a detector that cannot see typing "
                    + "fires while you type.") {
            VStack(alignment: .leading, spacing: 8) {
                permissionRow("Input Monitoring", "reads the accelerometer",
                              granted: engine.permissions.inputMonitoring) {
                    PermissionState.promptInputMonitoring()
                    PermissionState.openInputMonitoringPane()
                }
                permissionRow("Accessibility", "posts the hotkey and watches for typing",
                              granted: engine.permissions.accessibility) {
                    PermissionState.promptAccessibility()
                    PermissionState.openAccessibilityPane()
                }
            }
        }
        .transition(.opacity)
    }

    private func permissionRow(_ title: String, _ why: String, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(why).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            if !granted {
                Button("Open Settings", action: action).buttonStyle(TunkButtonStyle())
            }
        }
        .frame(minHeight: Metrics.hitTarget)
    }

    // MARK: - status

    private var statusCard: some View {
        Card(title: "Status") {
            HStack(alignment: .top, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .tunkAnimation(.tunkSnappy, value: engine.status,
                                       reduceMotion: reduceMotion)
                    Text(statusLabel)
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(minWidth: 120, alignment: .leading)

                Readout(label: "sample rate",
                        value: String(format: "%.0f Hz", engine.sampleRateHz))
                Readout(label: "fired", value: "\(engine.triggerCount)")
                Readout(label: "last latency",
                        value: engine.lastLatencyMs.map { String(format: "%.0f ms", $0) } ?? "—")
            }
            Toggle("Enable detection", isOn: $settings.enabled)
                .toggleStyle(.switch)
                .font(.system(size: 12))
                .frame(minHeight: Metrics.hitTarget)
                .contentShape(Rectangle())

            if let error = engine.lastEmitError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    private var statusColor: Color {
        switch engine.status {
        case .running: return .green
        case .off: return .secondary
        case .sensorLost, .needsPermission: return .orange
        }
    }

    private var statusLabel: String {
        switch engine.status {
        case .running: return "Listening"
        case .off: return "Off"
        case .needsPermission: return "Needs permission"
        case .sensorLost: return "Sensor lost"
        }
    }

    // MARK: - monitor

    private var monitorCard: some View {
        Card(title: "Tap monitor",
             caption: "Onsets as they land, with the gate window shaded. If a spike is grey "
                    + "the gate ate it on purpose — that is typing suppression working.") {
            TapMonitorView(model: monitor, armed: engine.status.isArmed)
        }
    }

    // MARK: - detection

    private var detectionCard: some View {
        Card(title: "Detection",
             caption: "These write straight into the detector. There is no second copy.") {
            slider(title: "Sensitivity",
                   value: $settings.config.sensitivity,
                   range: 0.4...2.0, step: 0.05,
                   readout: String(format: "%.2f×", settings.config.sensitivity),
                   help: "Lower fires on lighter taps. Higher needs a firmer knock.")

            slider(title: "Gate window",
                   value: Binding(
                    get: { Double(settings.config.gateWindowNs) / 1_000_000 },
                    set: { settings.config.gateWindowNs = Int64($0 * 1_000_000) }),
                   range: 0...400, step: 10,
                   readout: String(format: "%.0f ms", Double(settings.config.gateWindowNs) / 1_000_000),
                   help: "Onsets are ignored for this long after any keystroke or click. "
                       + "This is the knob that kills typing false positives.")

            HStack(spacing: 18) {
                Readout(label: "effective threshold",
                        value: String(format: "%.3f", settings.config.effectiveThreshold),
                        accent: .primary)
                Readout(label: "calibrated",
                        value: settings.config.calibratedThreshold
                            .map { String(format: "%.3f", $0) } ?? "not yet")
                Readout(label: "confirm window",
                        value: String(format: "%.0f ms",
                                      Double(settings.config.confirmWindowNs) / 1_000_000))
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    slider(title: "Min gap between taps",
                           value: msBinding(\.minInterTapNs), range: 40...200, step: 10,
                           readout: ms(settings.config.minInterTapNs), help: nil)
                    slider(title: "Max gap between taps",
                           value: msBinding(\.maxInterTapNs), range: 200...700, step: 10,
                           readout: ms(settings.config.maxInterTapNs), help: nil)
                    slider(title: "Confirm window",
                           value: msBinding(\.confirmWindowNs), range: 100...300, step: 10,
                           readout: ms(settings.config.confirmWindowNs),
                           help: "Tunk waits this long after the second tap so a third tap "
                               + "can be added later without changing how double feels.")
                    slider(title: "Refractory",
                           value: msBinding(\.refractoryNs), range: 200...1500, step: 50,
                           readout: ms(settings.config.refractoryNs), help: nil)
                    HStack {
                        Spacer()
                        Button("Reset to defaults") { settings.resetDetectionToDefaults() }
                            .buttonStyle(TunkButtonStyle())
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Timing")
                    .font(.system(size: 12, weight: .medium))
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
            }
            .tunkAnimation(.tunkSnappy, value: showAdvanced, reduceMotion: reduceMotion)
        }
    }

    private func msBinding(_ path: WritableKeyPath<DetectorConfig, Int64>) -> Binding<Double> {
        Binding(
            get: { Double(settings.config[keyPath: path]) / 1_000_000 },
            set: { settings.config[keyPath: path] = Int64($0 * 1_000_000) })
    }

    private func ms(_ ns: Int64) -> String {
        String(format: "%.0f ms", Double(ns) / 1_000_000)
    }

    private func slider(title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, step: Double,
                        readout: String, help: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(readout)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
                .frame(minHeight: 28)
            if let help {
                Text(help)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - hotkey

    private var hotkeyCard: some View {
        Card(title: "Emitted hotkey",
             caption: "Tunk posts this on a confirmed double-tap. Paste the same combination "
                    + "into VoiceInk → Settings → Shortcuts → Second Shortcut, recording mode "
                    + "\"toggle\". Leave your Right Shift binding alone.") {
            HStack(spacing: 8) {
                HotkeyRecorderView(binding: $settings.hotkey)
                Spacer()
                Button("Send it now", action: testEmit)
                    .buttonStyle(TunkButtonStyle())
                    .disabled(!engine.permissions.accessibility)
            }
            HStack(spacing: 18) {
                Readout(label: "paste into VoiceInk", value: settings.hotkey.description,
                        accent: .primary)
                Readout(label: "key downs / ups",
                        value: "\(engine.emitStats.keyDownsPosted) / "
                             + "\(engine.emitStats.keyUpsPosted)",
                        accent: engine.emitStats.hasStuckKey ? .orange : .secondary)
            }
            if let emitTestResult {
                Text(emitTestResult)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .tunkAnimation(.tunkSnappy, value: emitTestResult, reduceMotion: reduceMotion)
    }

    private func testEmit() {
        do {
            try engine.testEmit()
            emitTestResult = "Sent \(settings.hotkey.symbolicDescription) to the frontmost app."
        } catch {
            emitTestResult = error.localizedDescription
        }
    }

    // MARK: - calibration

    private var calibrationCard: some View {
        Card(title: "Calibration",
             caption: "Coupling changes with the machine and the surface, so the threshold "
                    + "comes from your own taps rather than a shipped constant.") {
            HStack(spacing: 12) {
                Readout(label: "current threshold",
                        value: settings.config.calibratedThreshold
                            .map { String(format: "%.3f", $0) } ?? "uncalibrated",
                        accent: settings.config.calibratedThreshold == nil ? .orange : .primary)
                Spacer()
                Button("Calibrate…") { panel.showCalibration = true }
                    .buttonStyle(TunkButtonStyle(prominent: settings.config.calibratedThreshold == nil))
            }
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sensor: built-in accelerometer, 796 Hz at a 1250 µs report interval.")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

import AppKit
import SwiftUI
import TunkCore
import TunkEmit

final class PanelModel: ObservableObject {
    @Published var showCalibration = false

    /// The tap monitor's 60 Hz poll loop, owned here so the window controller
    /// can start and stop it imperatively.
    ///
    /// It is deliberately not driven from SwiftUI. Two measured reasons, both
    /// from `tunk --cpu-probe`:
    ///
    ///  1. `onDisappear` never fires for a hosted view whose window is merely
    ///     ordered out, and this window is kept alive between opens so that
    ///     reopening shows it settled. That left the timer running forever
    ///     after the first open — 59 polls a second with the panel closed.
    ///  2. Passing visibility down as a `@Published` flag and reacting with
    ///     `onChange` does not work either: once the window closes, SwiftUI
    ///     stops running updates for that hierarchy, so the "now hidden" value
    ///     is never delivered to the view that would act on it.
    ///
    /// Anything that must stop when the panel closes has to be stopped by the
    /// thing that closed it.
    let monitor = MonitorStore()
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engine: Engine
    @ObservedObject var panel: PanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Slider floor for the gate window, in ms. A fast typist puts ~100 ms
    /// between keystrokes, so a gate much under this leaves gaps typing can
    /// fire through. The harness sets `DetectorConfig` directly and is not
    /// bound by this; the panel is where a user could do it by accident.
    /// The slider must not offer a value the next launch will revert.
    ///
    /// It floored at 60 ms while `SettingsMigration.minimumSafeGateNs` is
    /// 150 ms, so 60, 100 and 140 all ran at 180 ms after a relaunch — and the
    /// card that appeared said "These were saved by an earlier version of Tunk
    /// and no longer work the way they did", about a value this build's own
    /// slider had set minutes earlier. Offering a setting and then quietly
    /// undoing it is worse than not offering it.
    static let gateFloorMs = Double(SettingsMigration.minimumSafeGateNs) / 1_000_000
    /// Below this the panel explains the cost. The PRD's own starting range is
    /// 150–200 ms. Read from the migration's floor rather than restated, so the
    /// value the panel warns about and the value an upgrade silently raises
    /// cannot drift apart.
    static let gateCautionMs = Double(SettingsMigration.minimumSafeGateNs) / 1_000_000

    @State private var showAdvanced: Bool
    /// Keyed by tap count: each row's Test button reports into its own row.
    @State private var testResults: [Int: String] = [:]

    /// - Parameter showAdvanced: opens the Timing group. Only `--dump-panel`
    ///   passes true, so the timing sliders and their in-force readouts can be
    ///   reviewed as a rendered artifact rather than as a description.
    init(settings: AppSettings, engine: Engine, panel: PanelModel, showAdvanced: Bool = false) {
        self.settings = settings
        self.engine = engine
        self.panel = panel
        _showAdvanced = State(initialValue: showAdvanced)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 14) {
                if !engine.permissions.ready { permissionCard }
                if !settings.migrationNotes.isEmpty { migrationCard }
                statusCard
                monitorCard
                detectionCard
                // Double first: it is what ships armed and the reason the app
                // exists. Single sits below with its caution.
                ForEach(ActionBindings.wiredCounts, id: \.self) { actionCard(tapCount: $0) }
                calibrationCard
                lapPairingCard
                footnote
            }
            .padding(Metrics.panelPadding)
        }
        .frame(width: 452)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { engine.refreshShortcutCatalog() }
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

    // MARK: - migration

    /// Settings changed on this launch because they were unsafe or incoherent.
    /// Shown rather than applied quietly: rewriting someone's configuration
    /// without telling them is not better than leaving it broken.
    private var migrationCard: some View {
        Card(title: "Settings updated",
             caption: "These were saved by an earlier version of Tunk and no longer work the "
                    + "way they did. Everything you chose — your hotkeys, Shortcuts and tap "
                    + "bindings — is untouched.") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(settings.migrationNotes) { note in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(note.field)
                                .font(.system(size: 12, weight: .medium))
                            Text("\(note.was) → \(note.now)")
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                        }
                        Text(note.why)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Spacer()
                Button("Got it") { settings.dismissMigrationNotes() }
                    .buttonStyle(TunkButtonStyle())
            }
            .frame(minHeight: Metrics.hitTarget)
        }
        .transition(.opacity)
        .tunkAnimation(.tunkSnappy, value: settings.migrationNotes, reduceMotion: reduceMotion)
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
            TapMonitorView(engine: engine, armed: engine.status.isArmed,
                           store: panel.monitor)
            // A gesture the detector saw and deliberately did not act on. Without
            // this the app just looks broken to someone tapping three times.
            if let seen = engine.lastUnboundGesture,
               settings.bindings[seen.tapCount] == .none {
                Text("Last seen: \(gestureName(seen.tapCount)) — nothing bound to it, so "
                   + "Tunk did nothing.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func gestureName(_ count: Int) -> String {
        switch count {
        case 1:  return "1 tap"
        default: return "\(count) taps"
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

            // Floored, not free. The gate is the single mechanism that stops
            // typing from firing the detector, and the PRD calls typing false
            // positives the make-or-break metric — a slider that reaches 0
            // lets a user switch that defence off by dragging, with no idea
            // what they just did. The floor is 60 ms; below the PRD's own
            // 150 ms starting point the panel says what it costs.
            slider(title: "Gate window",
                   value: Binding(
                    get: { Double(settings.config.gateWindowNs) / 1_000_000 },
                    set: { settings.config.gateWindowNs = Int64($0 * 1_000_000) }),
                   range: Self.gateFloorMs...400, step: 10,
                   readout: String(format: "%.0f ms", Double(settings.config.gateWindowNs) / 1_000_000),
                   help: "Onsets are ignored for this long after any keystroke or click. "
                       + "This is the knob that kills typing false positives.")

            if Double(settings.config.gateWindowNs) / 1_000_000 < Self.gateCautionMs {
                Text("Below \(Int(Self.gateCautionMs)) ms the gate stops covering the gap "
                   + "between keystrokes, so typing can fire a tap. Raise it back to "
                   + "180 ms if Tunk starts triggering mid-sentence.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Read what is in force, not what was typed. The detector clamps
            // incoherent combinations on every write, so these two can differ —
            // and a readout showing the number that is not running would be
            // worse than no readout.
            let inForce = engine.effectiveConfig
            HStack(spacing: 18) {
                Readout(label: "effective threshold",
                        value: String(format: "%.3f", inForce.effectiveThreshold),
                        accent: .primary)
                Readout(label: "calibrated",
                        value: inForce.calibratedThreshold
                            .map { String(format: "%.3f", $0) } ?? "not yet")
                Readout(label: "confirm window",
                        value: String(format: "%.0f ms",
                                      Double(inForce.confirmWindowNs) / 1_000_000))
            }

            // What the clamp changed, in the detector's own words. Shown rather
            // than swallowed: a slider that silently does nothing past a certain
            // point reads as a bug.
            ForEach(engine.coherenceIssues, id: \.description) { issue in
                Text(issue.userFacingDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    slider(title: "Min gap between taps",
                           value: msBinding(\.minInterTapNs), range: 40...200, step: 10,
                           readout: msReadout(settings.config.minInterTapNs,
                                              inForce: inForce.minInterTapNs), help: nil)
                    slider(title: "Max gap between taps",
                           value: msBinding(\.maxInterTapNs), range: 200...700, step: 10,
                           readout: msReadout(settings.config.maxInterTapNs,
                                              inForce: inForce.maxInterTapNs), help: nil)
                    // Range starts at 160, not 100. Below that the app cannot
                    // detect a double-tap AT ALL, because madeCoherent() clamps
                    // maxInterTapNs down to the confirm window, so lowering this
                    // silently narrows the join window with it. Driven over the
                    // real detector at the spacings this project has measured on
                    // itself (desk 168-199 ms, soft 149-371 ms):
                    //
                    //   confirm 100/120/140 ms -> 0 of 8 double-taps detected
                    //   confirm 160 ms         -> 2 of 8
                    //   confirm 180 ms         -> 4 of 8
                    //   confirm 220 ms         -> 8 of 8   (shipped)
                    //
                    // The help text said the opposite: that this only governed
                    // room for a future third tap. A slider whose own minimum
                    // breaks the product is worse than no slider.
                    slider(title: "Confirm window",
                           value: msBinding(\.confirmWindowNs), range: 160...300, step: 10,
                           readout: msReadout(settings.config.confirmWindowNs,
                                              inForce: inForce.confirmWindowNs),
                           help: "How long Tunk waits after your second tap before acting. "
                               + "It is also the widest gap allowed between the two taps, so "
                               + "lowering it makes a slower double-tap stop registering: "
                               + "measured on this machine, 180 ms catches about half the "
                               + "gestures 220 ms catches. Raising it adds the same delay to "
                               + "every tap.")
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

    /// The slider's own number, and next to it the one the detector runs when
    /// the coherence clamp overrides it. The orange note below the card already
    /// explains why; this stops the readout itself from claiming a value that
    /// is not in force. The slider can reach 700 ms while the detector runs
    /// 220 ms, and a readout saying only "700 ms" is simply wrong.
    private func msReadout(_ stored: Int64, inForce: Int64) -> String {
        stored == inForce ? ms(stored) : "\(ms(stored)) → \(ms(inForce))"
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

    // MARK: - action rows

    private func rowTitle(_ count: Int) -> String {
        switch count {
        case 1:  return "Single tap"
        case 2:  return "Double tap"
        case 3:  return "Triple tap"
        default: return "\(count) taps"
        }
    }

    /// One row of the Back Tap model: a tap count, and the action bound to it.
    /// The kind picker is the only control always on screen; the rest of the
    /// card is whatever that kind needs.
    private func actionCard(tapCount count: Int) -> some View {
        Card(title: rowTitle(count), caption: rowCaption(count)) {
            Picker(rowTitle(count), selection: actionKind(count)) {
                Text("Send a hotkey").tag(TunkAction.Kind.hotkey)
                Text("Run a Shortcut").tag(TunkAction.Kind.shortcut)
                Text("Do nothing").tag(TunkAction.Kind.none)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(minHeight: 28)

            if count == 1 && settings.actionKind(for: 1) != .none { singleTapCaution }

            Group {
                switch settings.actionKind(for: count) {
                case .hotkey:   hotkeySection(count)
                case .shortcut: shortcutSection(count)
                case .none:     nothingSection(count)
                }
            }
            .transition(.opacity)

            actionFooter(count)
                .transition(.opacity.animation(.tunkSnappy.delay(Metrics.stagger)))
        }
        .tunkAnimation(.tunkSnappy, value: settings.bindings, reduceMotion: reduceMotion)
        .tunkAnimation(.tunkSnappy, value: testResults[count], reduceMotion: reduceMotion)
    }

    private func rowCaption(_ count: Int) -> String {
        count == 2
            ? "What a confirmed double-tap does. The gesture is fixed; the action is yours, "
            + "the way Back Tap works on iPhone."
            : "A single deliberate tap. Unbound by default."
    }

    /// Stated once, plainly, and only when the row is actually armed. The point
    /// is the measured reason, not alarm: one onset is what a mug, a footfall
    /// and a hard keystroke all produce, and requiring two is the entire
    /// false-positive defence.
    private var singleTapCaution: some View {
        Text("A single tap fires far more easily by accident than a double — one knock is "
           + "all a mug, a footfall or a hard keystroke produces. Measured on 40 minutes of "
           + "this machine doing ordinary things: single tap fires 3.5 times per 20 minutes "
           + "when nobody is tapping, and four of the seven were while typing. Double tap "
           + "fires zero times over the same recordings.")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionKind(_ count: Int) -> Binding<TunkAction.Kind> {
        Binding(get: { settings.actionKind(for: count) },
                set: { settings.setActionKind($0, for: count) })
    }

    // MARK: - action: hotkey

    private func hotkeySection(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HotkeyRecorderView(binding: Binding(
                get: { settings.hotkeyDraft(for: count) },
                set: { settings.setHotkeyDraft($0, for: count) }))
            // The reason the app exists. It stays on screen in this mode.
            Text("Paste the same combination into VoiceInk → Settings → Shortcuts → "
               + "Second Shortcut, recording mode \"toggle\". Leave your Right Shift "
               + "binding alone; it stays your manual trigger.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Readout(label: "paste into VoiceInk",
                        value: settings.hotkeyDraft(for: count).description, accent: .primary)
                Readout(label: "key downs / ups",
                        value: "\(engine.actionStats.emit.keyDownsPosted) / "
                             + "\(engine.actionStats.emit.keyUpsPosted)",
                        accent: engine.actionStats.hasStuckKey ? .orange : .secondary)
            }
        }
    }

    // MARK: - action: shortcut

    private func shortcutSection(_ count: Int) -> some View {
        let names = engine.shortcutNames
        let chosen = settings.shortcutDraft(for: count)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if names.isEmpty {
                    Text(engine.shortcutsReadable
                         ? "No Shortcuts found."
                         : "Tunk cannot read your Shortcuts.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Shortcut", selection: Binding(
                        get: { chosen },
                        set: { settings.setShortcutDraft($0, for: count,
                                                         pickedFromListing: names.contains($0)) })) {
                        if chosen.isEmpty {
                            Text("Choose a Shortcut…").tag("")
                        } else if !names.contains(chosen) {
                            // Renamed or deleted since it was chosen. Shown so
                            // the picker is not mysteriously blank, and so the
                            // reason is on screen next to it.
                            Text("\(chosen) (missing)").tag(chosen)
                        }
                        ForEach(names, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                Spacer()
                Button("Refresh") { engine.refreshShortcutCatalog() }
                    .buttonStyle(TunkButtonStyle())
                    .help("List your Shortcuts again. This reads the list; it runs nothing.")
            }
            .frame(minHeight: Metrics.hitTarget)

            if let broken = engine.brokenBinding, broken.tapCount == count {
                Text(broken.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(names.isEmpty
                     ? (engine.shortcutsReadable
                        ? "Add one in Shortcuts.app, then press Refresh."
                        : "Open Shortcuts.app once, then press Refresh.")
                     : "Tunk starts the Shortcut and returns immediately, so a slow Shortcut "
                     + "never delays detection. It runs only on a real tap or on Test.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - action: nothing

    private func nothingSection(_ count: Int) -> some View {
        Text(count == 1
             ? "Nothing is bound to a single tap. Single taps are still detected and drawn in "
             + "the monitor above; Tunk just does not act on them."
             : "Taps are still detected, counted and drawn in the monitor above — Tunk just "
             + "does not send anything. Useful while you tune sensitivity.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - action: per-row footer

    private func actionFooter(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                // Only the row that last fired shows a latency. Attributing
                // another row's number to this one would be a lie.
                let mine = engine.actionStats.lastTapCount == count
                // Decision to handoff. This is the figure the 250 ms target is
                // measured against, and it stays near a millisecond whatever the
                // action does afterwards.
                Readout(label: "dispatch",
                        value: mine ? (engine.actionStats.lastDispatchMs
                            .map { String(format: "%.2f ms", $0) } ?? "—") : "—")
                if settings.actionKind(for: count) == .shortcut {
                    // Reported, never waited on. A nine-second Shortcut is not a
                    // Tunk latency failure.
                    Readout(label: "Shortcut took",
                            value: mine ? (engine.actionStats.lastCompletionMs
                                .map { String(format: "%.0f ms", $0) } ?? "—") : "—")
                }
                Spacer()
                Button("Test") { runTest(count) }
                    .buttonStyle(TunkButtonStyle())
                    .disabled(!canTest(count))
                    .help(testHelp(count))
            }
            .frame(minHeight: Metrics.hitTarget)

            if let text = testResults[count] {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func canTest(_ count: Int) -> Bool {
        guard settings.bindings[count].isRunnable else { return false }
        guard settings.actionKind(for: count) == .hotkey else { return true }
        return engine.permissions.accessibility
    }

    private func testHelp(_ count: Int) -> String {
        switch settings.actionKind(for: count) {
        case .hotkey:   return "Send this combination to the frontmost app once"
        case .shortcut: return "Run this Shortcut once, now"
        case .none:     return "Nothing to test"
        }
    }

    private func runTest(_ count: Int) {
        do {
            let stats = try engine.testAction(tapCount: count)
            // A stale name never spawns, so a Test on one reports the reason
            // rather than claiming it ran.
            if let text = stats.lastErrorText {
                testResults[count] = text
                return
            }
            switch settings.bindings[count] {
            case .hotkey(let spec):
                testResults[count] = "Sent \(spec.symbolicDescription) to the frontmost app."
            case .shortcut(let name, _):
                testResults[count] = "Started \"\(name)\". Tunk does not wait for it to finish."
            case .none:
                testResults[count] = nil
            }
        } catch {
            testResults[count] = error.localizedDescription
        }
    }

    // MARK: - calibration

    private var calibrationCard: some View {
        Card(title: "Calibration",
             caption: "Coupling changes with the machine and the surface, so the threshold "
                    + "comes from your own taps rather than a shipped constant.") {
            HStack(spacing: 12) {
                // "learned from your taps", not "current threshold". The raw
                // calibrated value is NOT what the detector runs: the
                // sensitivity slider multiplies it, so at 1.35x this card read
                // 0.043 while the detector ran 0.058. Naming a number after
                // what it is beats showing a number that is not in force, and
                // the effective bar already has its own readout on the
                // Detection card.
                Readout(label: "learned from your taps",
                        value: settings.config.calibratedThreshold
                            .map { String(format: "%.3f", $0) } ?? "uncalibrated",
                        accent: settings.config.calibratedThreshold == nil ? .orange : .primary)
                if let learned = settings.config.calibratedThreshold,
                   abs(engine.effectiveConfig.effectiveThreshold - learned) > 0.0005 {
                    Readout(label: "in force",
                            value: String(format: "%.3f",
                                          engine.effectiveConfig.effectiveThreshold),
                            accent: .accentColor)
                }
                Spacer()
                Button("Calibrate…") { panel.showCalibration = true }
                    .buttonStyle(TunkButtonStyle(prominent: settings.config.calibratedThreshold == nil))
            }
        }
    }

    // MARK: - experimental

    /// The one unproven mechanism the app can switch on. It sits last, below
    /// calibration, because nothing above it depends on it and because an owner
    /// scrolling past should be able to ignore it.
    ///
    /// Every number in this card was measured. The three lines under the toggle
    /// are the three reasons its critics stopped it from shipping on, kept in the
    /// UI verbatim rather than summarised into a benefit: an owner who turns this
    /// on is volunteering to be the experiment, and cannot volunteer for
    /// something they have not been told.
    private var lapPairingCard: some View {
        Card(title: "Lap pairing (experimental)",
             caption: "Changes how a second tap is recovered when the first one is still "
                    + "ringing through a soft surface. It is the only mechanism that has "
                    + "reached the lap detection target on recordings it was not tuned on, "
                    + "and it is not approved for shipping on.") {
            Toggle("Use experimental lap pairing", isOn: $settings.experimentalLapPairing)
                .toggleStyle(.switch)
                .font(.system(size: 12))
                .frame(minHeight: Metrics.hitTarget)
                .contentShape(Rectangle())

            HStack(spacing: 18) {
                Readout(label: "held-out lap, off", value: "16/20")
                Readout(label: "held-out lap, on", value: "20/20", accent: .primary)
                Readout(label: "held-out lap p95, on", value: "203.9 ms")
            }

            Text("Desk and soft read 20 of 20 either way, and every held-out recording reads "
               + "zero false triggers with this on or off. Latency does not move: the lap "
               + "figure is 208.9 ms with this off.\n\n"
               + "Read the 20 of 20 with the asterisk the scorer prints beside it: 5 of those "
               + "20 credits land more than 40 ms from where the label puts the gesture, "
               + "against 2 of 16 with this off. The worst is 105 ms out. Those five are the "
               + "gestures whose two taps the labels place further apart than any detector is "
               + "allowed to pair, so it fires on a real pair inside the gesture rather than "
               + "the labelled one.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                caveat("On the lap recordings it adds two false triggers in nine minutes, "
                     + "against three for the shipped detector. The concern is what has not "
                     + "been recorded: a lap damps so slowly that a lone knock is still "
                     + "ringing 100 to 220 ms later at about half its strength, which is "
                     + "exactly where this looks for a second tap. Whether that fires in "
                     + "practice is unmeasured — the recordings hold only two knocks with "
                     + "no deliberate tap either side. Three separate guards have been "
                     + "built to close it and all three failed.")
                caveat("It takes the second tap from a crest at half the usual bar. Two of the "
                     + "five false triggers on the lap recordings it was tuned on arrive that "
                     + "way, and no test of amplitude can tell them from a real gesture.")
                caveat("It leans harder on the gate that stops your typing from firing Tunk. "
                     + "Across 11.7 minutes of typing recordings, with the gate's 180 ms "
                     + "window set to zero — its other 25 ms of suppression cannot be "
                     + "switched off and was still running — the shipped detector fires 62 "
                     + "times and this fires 124. Stripping the keystroke record entirely, "
                     + "which is the fuller test, the same pair reads 2.4x rather than 2.0x. "
                     + "The gate turns both into zero. Turning this on asks it to catch "
                     + "between twice and two and a half times as much.")
            }
        }
        .tunkAnimation(.tunkSnappy, value: settings.experimentalLapPairing,
                       reduceMotion: reduceMotion)
    }

    private func caveat(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Color.orange)
                .frame(width: 4, height: 4)
                // Optical, not geometric: a 4 pt dot centred on an 11 pt line
                // sits high, and the line it belongs to is the first one.
                .padding(.top, 5)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

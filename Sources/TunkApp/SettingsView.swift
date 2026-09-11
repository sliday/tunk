import AppKit
import SwiftUI
import TunkCore
import TunkEmit

/// The four pages of the settings window. Sidebar order.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, actions, calibration, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:     return "General"
        case .actions:     return "Actions"
        case .calibration: return "Calibration"
        case .advanced:    return "Advanced"
        }
    }

    var caption: String {
        switch self {
        case .general:     return "Turn detection on, watch taps land, and choose what a double-tap does."
        case .actions:     return "One action per tap count. Double tap is on by default; single tap is off."
        case .calibration: return "Teach Tunk how hard you tap, and how long to ignore taps after typing."
        case .advanced:    return "Timing, the raw signal, and two experiments that ship off."
        }
    }

    var symbol: String {
        switch self {
        case .general:     return "switch.2"
        case .actions:     return "keyboard"
        case .calibration: return "waveform.path.ecg"
        case .advanced:    return "slider.horizontal.3"
        }
    }
}

final class PanelModel: ObservableObject {
    @Published var showCalibration = false
    /// Which page is showing. Owned here so the window controller can land the
    /// user on Calibration when the menu's Calibrate… opened the window.
    @Published var section: SettingsSection = .general
    /// Opens the first-run window. Set by the window controller; nil under
    /// `--dump-panel`, where the button renders and does nothing.
    var openSetup: (() -> Void)?

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

    /// Window width. Fixed: the sidebar is 168 pt and the content column is
    /// sized for one card width, so stretching sideways would only strand the
    /// readouts. The window controller and `--dump-panel` both read this.
    static let width: CGFloat = 640
    static let sidebarWidth: CGFloat = 168

    /// The lap-pairing card carries three long caveats. Collapsed by default so
    /// the page keeps its rhythm; every word is still one click away, and
    /// `--dump-panel` opens it so the copy is reviewable as a rendered artifact.
    @State private var showLapPairingDetail: Bool
    /// Keyed by tap count: each row's Test button reports into its own row.
    @State private var testResults: [Int: String] = [:]
    /// Only `--dump-panel` sets this. The permission card appears only when a
    /// grant is missing, and a dump made from a terminal that has both grants
    /// would never show it; forcing the state here is how the card gets
    /// rendered without revoking anything.
    private let forcedPermissions: PermissionState?

    /// - Parameter showAdvanced: opens the lap-pairing caveats. Only
    ///   `--dump-panel` passes true, so the copy can be reviewed as a rendered
    ///   artifact rather than as a description.
    /// - Parameter forcedPermissions: what the view should believe macOS has
    ///   granted, overriding the engine's reading. `--dump-panel` only.
    init(settings: AppSettings, engine: Engine, panel: PanelModel, showAdvanced: Bool = false,
         forcedPermissions: PermissionState? = nil) {
        self.settings = settings
        self.engine = engine
        self.panel = panel
        self.forcedPermissions = forcedPermissions
        _showLapPairingDetail = State(initialValue: showAdvanced)
    }

    private var permissions: PermissionState { forcedPermissions ?? engine.permissions }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader
                    switch panel.section {
                    case .general:     generalPage
                    case .actions:     actionsPage
                    case .calibration: calibrationPage
                    case .advanced:    advancedPage
                    }
                }
                .padding(Metrics.panelPadding)
                // Room for the title bar, which overlays the content.
                .padding(.top, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: Self.width)
        .onAppear { engine.refreshShortcutCatalog() }
        .sheet(isPresented: $panel.showCalibration) {
            CalibrationView(engine: engine) { panel.showCalibration = false }
        }
    }

    // MARK: - sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tunk")
                    .font(.system(size: 15, weight: .bold))
                Text("Double tap. Do more.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            // Clears the traffic lights, which sit over the sidebar.
            .padding(.top, 44)
            .padding(.bottom, 16)

            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    sidebarRow(section)
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 16)

            // The same entry as the menu's, so the walkthrough is reachable
            // from wherever a person happens to be looking.
            Button("Set up Tunk…") { panel.openSetup?() }
                .buttonStyle(TunkButtonStyle())
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text("Reads only the accelerometer. Nothing leaves your Mac.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tunk \(Self.version)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        // A shade off the content column, in both appearances, without a
        // hairline between them.
        .background(Color(nsColor: .windowBackgroundColor)
                        .overlay(Color.primary.opacity(0.045)))
    }

    private static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        let selected = panel.section == section
        return Button {
            panel.section = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(selected ? Color.tunkAmber : Color.secondary)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.09) : Color.clear)
            )
            .contentShape(Rectangle())
            .frame(minHeight: Metrics.hitTarget)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .tunkAnimation(.tunkQuick, value: selected, reduceMotion: reduceMotion)
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(panel.section.title)
                .font(.system(size: 17, weight: .bold))
            Text(panel.section.caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    // MARK: - pages

    /// Everything a non-technical person needs, and nothing that needs a
    /// glossary. Fits 680 pt without scrolling when both permissions are
    /// granted and no migration note is pending; either card pushes it over,
    /// and both are cards the user is meant to act on and dismiss.
    @ViewBuilder private var generalPage: some View {
        if !permissions.ready { permissionCard }
        if !settings.migrationNotes.isEmpty { migrationCard }
        statusCard
        monitorCard
        actionCard(tapCount: 2, compact: true)
    }

    @ViewBuilder private var actionsPage: some View {
        // Double first: it is what ships armed and the reason the app exists.
        // Single sits below with its caution.
        ForEach(ActionBindings.wiredCounts, id: \.self) { actionCard(tapCount: $0, compact: false) }
    }

    @ViewBuilder private var calibrationPage: some View {
        calibrationCard
        detectionCard
    }

    @ViewBuilder private var advancedPage: some View {
        timingCard
        signalCard
        lapPairingCard
        footnote
    }

    // MARK: - permissions

    private var permissionCard: some View {
        Card(title: "Tunk needs two permissions",
             caption: "Detection stays off until both are granted. Set up Tunk… walks "
                    + "you through them.") {
            VStack(alignment: .leading, spacing: 8) {
                permissionRow(PermissionState.inputMonitoringName,
                              PermissionState.inputMonitoringWhy,
                              granted: permissions.inputMonitoring) {
                    PermissionState.promptInputMonitoring()
                    PermissionState.openInputMonitoringPane()
                }
                permissionRow(PermissionState.accessibilityName,
                              PermissionState.accessibilityWhy,
                              granted: permissions.accessibility) {
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
                .fill(granted ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(why)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(granted ? "Granted" : "Not granted")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(granted ? Color.green : Color.red)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill((granted ? Color.green : Color.red).opacity(0.12)))
            if !granted {
                // Never truncated: the reason column wraps instead.
                Button(PermissionState.openButtonTitle, action: action)
                    .buttonStyle(TunkButtonStyle())
                    .fixedSize()
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
        Card(title: nil) {
            HStack(alignment: .center, spacing: 14) {
                Toggle("Enable detection", isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
                    .frame(minHeight: Metrics.hitTarget)
                    .contentShape(Rectangle())
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .tunkAnimation(.tunkSnappy, value: engine.status,
                                       reduceMotion: reduceMotion)
                    Text(statusLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 18) {
                Readout(label: "sample rate",
                        value: String(format: "%.0f Hz", engine.sampleRateHz))
                Readout(label: "taps fired", value: "\(engine.triggerCount)")
                Readout(label: "last latency",
                        value: engine.lastLatencyMs.map { String(format: "%.0f ms", $0) } ?? "—")
            }
            // The live tuning is named in full under Advanced. Here it only has
            // to be impossible to miss.
            if !Self.nonDefaultParts(engine.liveTuning).isEmpty {
                Text("Running an experiment, not the shipped detector. See Advanced.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        case .sensorLost: return "Sensor unavailable"
        }
    }

    // MARK: - monitor

    private var monitorCard: some View {
        Card(title: "Tap monitor",
             caption: "Taps as they land. A grey spike was ignored because you were typing.") {
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

    // MARK: - detection (Calibration page)

    private var detectionCard: some View {
        Card(title: "Sensitivity",
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
            // what they just did. Below the PRD's own 150 ms starting point the
            // panel says what it costs.
            slider(title: "Ignore taps after typing",
                   value: Binding(
                    get: { Double(settings.config.gateWindowNs) / 1_000_000 },
                    set: { settings.config.gateWindowNs = Int64($0 * 1_000_000) }),
                   range: Self.gateFloorMs...400, step: 10,
                   readout: String(format: "%.0f ms", Double(settings.config.gateWindowNs) / 1_000_000),
                   help: "Taps are ignored for this long after any keystroke or click. "
                       + "This is the knob that stops typing from firing Tunk.")

            if Double(settings.config.gateWindowNs) / 1_000_000 < Self.gateCautionMs {
                Text("Below \(Int(Self.gateCautionMs)) ms this stops covering the gap "
                   + "between keystrokes, so typing can fire a tap. Raise it back to "
                   + "180 ms if Tunk starts triggering mid-sentence.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - timing (Advanced page)

    private var timingCard: some View {
        // Read what is in force, not what was typed. The detector clamps
        // incoherent combinations on every write, so these two can differ —
        // and a readout showing the number that is not running would be
        // worse than no readout.
        let inForce = engine.effectiveConfig
        let frontEnd = engine.liveTuning
        return Card(title: "Timing",
                    caption: "Gaps and windows in milliseconds. The readouts show what the "
                           + "detector is running right now.") {
            // Anything running that is not the shipped detector gets named here,
            // read from the LIVE detector rather than from the switches. The
            // harness prints the same warning on a run; the app said nothing, so
            // a switched-on experiment looked exactly like the default. It is
            // also the only way to see that a switch reached the detector at all.
            if !Self.nonDefaultParts(frontEnd).isEmpty {
                Text("Running an experiment: "
                   + Self.nonDefaultParts(frontEnd).joined(separator: ", ")
                   + ". Not the shipped detector.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
    }

    /// The monitor's numbers, in the detector's units. They move at 6 Hz while
    /// the panel is open and belong next to the timing sliders, not on the page
    /// a first-time user lands on.
    private var signalCard: some View {
        Card(title: "Live signal",
             caption: "Everything in g, the unit the detector thresholds in. Same feed as "
                    + "the tap monitor on General.") {
            MonitorNumbersView(model: panel.monitor.numbers)
                .opacity(engine.status.isArmed ? 1 : 0.4)
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
    ///
    /// - Parameter compact: the General page's copy of the double-tap row. Same
    ///   controls writing the same settings; it leaves out the emission counters
    ///   and the Shortcut timing, which live on the full row under Actions.
    private func actionCard(tapCount count: Int, compact: Bool) -> some View {
        Card(title: rowTitle(count),
             caption: rowCaption(count, compact: compact)) {
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
                case .hotkey:   hotkeySection(count, compact: compact)
                case .shortcut: shortcutSection(count)
                case .none:     nothingSection(count)
                }
            }
            .transition(.opacity)

            actionFooter(count, compact: compact)
                .transition(.opacity.animation(.tunkSnappy.delay(Metrics.stagger)))
        }
        .tunkAnimation(.tunkSnappy, value: settings.bindings, reduceMotion: reduceMotion)
        .tunkAnimation(.tunkSnappy, value: testResults[count], reduceMotion: reduceMotion)
    }

    private func rowCaption(_ count: Int, compact: Bool) -> String {
        switch (count, compact) {
        case (2, true):
            return "What a confirmed double-tap does, the way Back Tap works on iPhone."
        case (2, false):
            return "What a confirmed double-tap does. The gesture is fixed; the action is yours, "
                + "the way Back Tap works on iPhone."
        default:
            return "A single deliberate tap. Unbound by default."
        }
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

    private func hotkeySection(_ count: Int, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HotkeyRecorderView(binding: Binding(
                get: { settings.hotkeyDraft(for: count) },
                set: { settings.setHotkeyDraft($0, for: count) }))
            // The reason the app exists. It stays on screen in this mode.
            Text("Paste the same combination into VoiceInk → Settings → Shortcuts → "
               + "Second Shortcut, recording mode \"toggle\". Your existing VoiceInk "
               + "shortcut keeps working.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !compact {
                HStack(spacing: 18) {
                    Readout(label: "key downs / ups",
                            value: "\(engine.actionStats.emit.keyDownsPosted) / "
                                 + "\(engine.actionStats.emit.keyUpsPosted)",
                            accent: engine.actionStats.hasStuckKey ? .orange : .secondary)
                }
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
             + "the tap monitor; Tunk just does not act on them."
             : "Taps are still detected, counted and drawn in the tap monitor — Tunk just "
             + "does not send anything. Useful while you tune sensitivity.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - action: per-row footer

    private func actionFooter(_ count: Int, compact: Bool) -> some View {
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
                if !compact, settings.actionKind(for: count) == .shortcut {
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
        return permissions.accessibility
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
                testResults[count] = "Sent \(spec.description) to the frontmost app."
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
                // the effective bar already has its own readout under Advanced.
                Readout(label: "learned from your taps",
                        value: settings.config.calibratedThreshold
                            .map { String(format: "%.3f", $0) } ?? "uncalibrated",
                        accent: settings.config.calibratedThreshold == nil ? .orange : .primary)
                if let learned = settings.config.calibratedThreshold,
                   abs(engine.effectiveConfig.effectiveThreshold - learned) > 0.0005 {
                    Readout(label: "in force",
                            value: String(format: "%.3f",
                                          engine.effectiveConfig.effectiveThreshold),
                            accent: .tunkAmber)
                }
                Spacer()
                Button("Calibrate…") { panel.showCalibration = true }
                    .buttonStyle(TunkButtonStyle(prominent: settings.config.calibratedThreshold == nil))
            }
        }
    }

    // MARK: - experimental

    /// The one unproven mechanism the app can switch on. It sits last, under
    /// Advanced, because nothing else depends on it and because an owner who
    /// never opens that page should be able to ignore it.
    ///
    /// Every number in this card was measured. The three lines under the toggle
    /// are the three reasons its critics stopped it from shipping on, kept in the
    /// UI verbatim rather than summarised into a benefit: an owner who turns this
    /// on is volunteering to be the experiment, and cannot volunteer for
    /// something they have not been told.
    private var lapPairingCard: some View {
        Card(title: "Lap detection (experimental)",
             caption: "Two independent switches, both off, both aimed at the one surface "
                    + "that misses taps. They were graded separately and can be used "
                    + "separately. Neither reaches the detection target, and each states "
                    + "what it costs.") {
            Toggle("Use the resonator front end", isOn: $settings.experimentalResonator)
                .toggleStyle(.switch)
                .font(.system(size: 12))
                .frame(minHeight: Metrics.hitTarget)
                .contentShape(Rectangle())

            Text("A separate, independently graded change: a 40 Hz filter before the "
               + "detector. A critic ruled it should ship on — held-out lap goes 16 of 20 "
               + "to 19 of 20 with desk and soft unchanged and latency up 1.2 ms. It is a "
               + "switch and not the default because turning it on trades a false-trigger "
               + "figure that currently passes on the recordings (0.00 per 20 min) for one "
               + "that does not (4.35), and 19 of 20 is still short of the target. It does "
               + "not touch your sensitivity: the threshold it needs is applied while it is "
               + "on and your own setting comes back when it is off.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider().opacity(0.5)

            Toggle("Use experimental lap pairing", isOn: $settings.experimentalLapPairing)
                .toggleStyle(.switch)
                .font(.system(size: 12))
                .frame(minHeight: Metrics.hitTarget)
                .contentShape(Rectangle())

            HStack(spacing: 18) {
                Readout(label: "lap, pairing off", value: "16/20")
                Readout(label: "lap, pairing on", value: "20/20", accent: .primary)
                Readout(label: "lap p95, pairing on", value: "203.9 ms")
            }

            Text("Desk and soft read 20 of 20 either way, latency does not move, and its "
               + "false triggers on a lap have never been measured — which is why it is off.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            DisclosureGroup(isExpanded: $showLapPairingDetail) {
                lapPairingDetail.padding(.top, 8)
            } label: {
                Text("What is measured, and what is not")
                    .font(.system(size: 12, weight: .medium))
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
            }
            .tunkAnimation(.tunkSnappy, value: showLapPairingDetail, reduceMotion: reduceMotion)
        }
        .tunkAnimation(.tunkSnappy, value: settings.experimentalLapPairing,
                       reduceMotion: reduceMotion)
    }

    /// Everything the owner needs before switching it on, kept out of the page's
    /// default rhythm because it is three screens of caveat on an off-by-default
    /// experiment. Nothing here is softened; it is only folded.
    private var lapPairingDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Read the 20 of 20 with the asterisk the scorer prints beside it: 5 of those "
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
                caveat("Its false triggers on the lap recordings are not measured, and the "
                     + "numbers that look like a measurement are not one. The two it adds "
                     + "were traced back to the raw signal and are both real taps you made: "
                     + "one struck 172 ms before the cue beep, one where the label pairs the "
                     + "first and third strikes across 434 ms and skips the one between. The "
                     + "shipped detector's three sit on labels of the same kind. Neither "
                     + "count means what it appears to.")
                caveat("What is genuinely untested is a lone knock. A lap damps so slowly "
                     + "that a single contact is still ringing 100 to 220 ms later at about "
                     + "half its strength, which is exactly where this looks for a second "
                     + "tap — and it takes that second tap at half the usual bar. Nobody has "
                     + "recorded this laptop being knocked on a lap without a deliberate tap, "
                     + "so the rate is unknown. Five guards have been built to close it and "
                     + "all five failed, because rejecting one crest just promotes the next "
                     + "one 15 ms away.")
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
    }

    /// Everything about the live tuning that differs from the shipped one, in
    /// plain words. Empty when the detector is the shipped one, which is the
    /// case this must get right: a false alarm here would train an owner to
    /// ignore the line.
    static func nonDefaultParts(_ t: DSPTuning) -> [String] {
        let d = DSPTuning.default
        var parts: [String] = []
        if t.resonatorHz != d.resonatorHz || t.resonatorQ != d.resonatorQ {
            parts.append(String(format: "resonator %.0f Hz Q %.1f", t.resonatorHz, t.resonatorQ))
        }
        if t.pairRescueEnabled != d.pairRescueEnabled {
            parts.append("lap pairing")
        }
        return parts
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

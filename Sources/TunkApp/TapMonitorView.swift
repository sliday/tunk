import AppKit
import SwiftUI
import TunkCore

/// The one real-time surface in the app, and the only place where redraw cost
/// matters. Three rules hold it together:
///
///  1. The sensor runs at 796 Hz. The UI samples it at the display rate, never
///     the other way round.
///  2. The trace and the numbers redraw on separate clocks — 60 Hz for the
///     shapes, 6 Hz for the text. Text layout is what costs; a number that
///     changes sixty times a second is unreadable anyway.
///  3. Nothing above this view observes either clock, so a moving trace never
///     invalidates the sliders, the cards or the window chrome.
///
/// Measured on this machine (M4 Max, 120 Hz display). Each figure says when it
/// applies, because the one that used to be here did not and that made a
/// correct number misleading:
///
///  - Fresh launch, Settings never opened: **1.1–1.3 %** of one core, sensor
///    running at 796 Hz. Measured twice by different means that agree —
///    `top -l 3` against the .app bundle, and `tunk --cpu-probe` phase 1.
///  - Panel open: **5.8–8.4 %**, polling at ~59 Hz.
///  - Panel closed again: **1.8–2.1 %**. Slightly above a fresh launch because
///    the window is kept alive rather than released, which is the trade that
///    makes reopening show it already settled.
///
/// That last line is the one that needed fixing. `stop()` used to hang off
/// SwiftUI's `onDisappear`, which never fires for a window that is ordered out
/// rather than unmounted — and this window is deliberately kept alive between
/// opens. So the timer ran forever after the first visit to Settings, and the
/// app sat at 6–12 % whether the panel was open or not. The fresh-launch figure
/// stayed true; it just stopped describing the app the moment anyone opened
/// Settings once.
///
/// `tunk --cpu-probe` measures all three phases and exits non-zero if the
/// monitor is still polling with the panel closed. Run it before putting a new
/// number in this comment.
final class MonitorStore {
    let trace = TraceModel()
    let numbers = NumbersModel()

    /// Every poll this process has done, across every store. Read by
    /// `tunk --cpu-probe` to prove the timer really stops when the panel
    /// closes, rather than inferring it from a CPU figure that moves for other
    /// reasons. Main thread only, which is where `pull()` runs.
    static private(set) var totalPulls = 0

    private var timer: Timer?
    private weak var engine: Engine?
    private var frameIndex = 0

    /// Seconds of history drawn.
    static let window: Double = 3.5
    /// One numbers update per this many frames.
    private static let textDivider = 10

    func start(engine: Engine) {
        self.engine = engine
        guard timer == nil else { return }
        let fps = min(max(NSScreen.main?.maximumFramesPerSecond ?? 60, 30), 60)
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(fps), repeats: true) {
            [weak self] _ in self?.pull()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        pull()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    var isRunning: Bool { timer != nil }

    deinit { timer?.invalidate() }

    private func pull() {
        Self.totalPulls += 1
        guard let engine else { return }
        let snap = engine.snapshot()
        trace.update(snap)

        // Publishes only when the gate actually flips, so the pill animates on
        // the transition and costs nothing in between.
        let active = snap.gateSpans.last.map { snap.nowNs <= $0.upperBound } ?? false
        numbers.setGate(active)

        frameIndex += 1
        if frameIndex % Self.textDivider == 0 { numbers.update(snap) }
    }
}

/// 60 Hz. Shapes only.
final class TraceModel: ObservableObject {
    @Published private(set) var frame = MonitorSnapshot()
    /// Slowly-decaying ceiling so the trace auto-scales without flickering.
    private(set) var scale: Double = 0.02

    func update(_ snap: MonitorSnapshot) {
        let peak = Double(snap.envelope.max() ?? 0)
        scale = max(peak, scale * 0.97, 0.02)
        frame = snap
    }
}

/// 6 Hz, plus an immediate update whenever the gate flips.
final class NumbersModel: ObservableObject {
    @Published private(set) var envelope = "0.000"
    @Published private(set) var threshold = "0.000"
    @Published private(set) var noiseFloor = "0.000"
    @Published private(set) var onsetCount = "0"
    @Published private(set) var gateActive = false

    func update(_ snap: MonitorSnapshot) {
        envelope = format(Double(snap.envelope.last ?? 0))
        threshold = format(snap.threshold)
        noiseFloor = format(snap.noiseFloor)
        onsetCount = "\(snap.onsets.count)"
    }

    func setGate(_ active: Bool) {
        guard active != gateActive else { return }
        gateActive = active
    }

    private func format(_ value: Double) -> String { String(format: "%.3f", value) }
}

/// Draws the monitor. It does not own the poll loop and does not start or stop
/// it — `SettingsWindowController` does, on window visibility. See
/// `PanelModel.monitor` for why the view's own lifecycle cannot be trusted.
struct TapMonitorView: View {
    let engine: Engine
    var armed: Bool
    let store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                TraceView(model: store.trace)
                if armed {
                    GatePill(model: store.numbers, armed: armed).padding(8)
                } else {
                    // Without this the panel shows an empty trace and a column
                    // of 0.000 readings, which reads as a broken chart rather
                    // than as a switch being off. Say which it is.
                    idleOverlay
                }
            }
            MonitorNumbers(model: store.numbers)
                .opacity(armed ? 1 : 0.4)
            legend
        }
    }

    private var idleOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                .fill(.background.opacity(0.55))
            VStack(spacing: 3) {
                Text("Detection is off")
                    .font(.system(size: 12, weight: .medium))
                Text("Turn it on above to watch onsets land.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .allowsHitTesting(false)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            swatch(Color.accentColor, "onset", dashed: false)
            swatch(Color.secondary.opacity(0.6), "suppressed", dashed: false)
            swatch(Color.orange.opacity(0.4), "gate window", dashed: false)
            swatch(Color.accentColor.opacity(0.6), "threshold", dashed: true)
            Spacer()
            Text("3.5 s · √g")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    private func swatch(_ color: Color, _ label: String, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            if dashed {
                Rectangle().fill(color).frame(width: 3, height: 2)
                Rectangle().fill(color).frame(width: 3, height: 2)
            } else {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 8, height: 3)
            }
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

/// Everything here is in g, the unit the detector thresholds in.
private struct MonitorNumbers: View {
    @ObservedObject var model: NumbersModel

    var body: some View {
        HStack(spacing: 18) {
            Readout(label: "envelope, g", value: model.envelope)
            Readout(label: "threshold, g", value: model.threshold, accent: .accentColor)
            Readout(label: "noise floor, g", value: model.noiseFloor)
            Readout(label: "onsets, 3.5 s", value: model.onsetCount)
        }
    }
}

private struct GatePill: View {
    @ObservedObject var model: NumbersModel
    var armed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.gateActive ? Color.orange : Color.green)
                .frame(width: 6, height: 6)
            Text(model.gateActive ? "SUPPRESSING" : "GATE OPEN")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(model.gateActive ? Color.orange : Color.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.85)))
        .opacity(armed ? 1 : 0.35)
        .tunkAnimation(.tunkSnappy, value: model.gateActive, reduceMotion: reduceMotion)
    }
}

/// Shapes only. No `Text` inside the canvas: resolving a string for layout on
/// every frame costs more than the whole rest of the drawing put together.
private struct TraceView: View {
    @ObservedObject var model: TraceModel

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            draw(context: &context, size: size)
        }
        .frame(height: 118)
        .background(
            RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .clipShape(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
        .accessibilityLabel("Tap monitor")
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let frame = model.frame
        let windowNs = Int64(MonitorStore.window * 1_000_000_000)
        let startNs = frame.nowNs - windowNs
        guard windowNs > 0 else { return }

        func x(_ tNs: Int64) -> CGFloat {
            CGFloat(Double(tNs - startNs) / Double(windowNs)) * size.width
        }

        // One vertical scale in g for the trace, the spikes and the line, with
        // headroom so a hard tap does not clip flat.
        let scale = max(model.scale, frame.threshold * 1.6, 1e-4)
        let usable = size.height * 0.94
        // Square-root axis. An uncalibrated threshold sits at 0.30 g while the
        // resting noise floor is nearer 0.001 g; on a linear axis one of the two
        // is always a flat line on the floor. This shows both at once.
        func y(_ value: Double) -> CGFloat {
            let unit = min(max(value, 0) / scale, 1)
            return size.height - CGFloat(unit.squareRoot()) * usable
        }

        // Gate windows, behind everything.
        for span in frame.gateSpans {
            let x0 = x(max(span.lowerBound, startNs))
            let x1 = x(min(span.upperBound, frame.nowNs))
            guard x1 > x0 else { continue }
            context.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)),
                         with: .color(.orange.opacity(0.16)))
        }

        // The detector's own transient envelope, in g.
        if !frame.envelope.isEmpty {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for i in 0..<frame.envelope.count {
                let px = x(frame.startNs + Int64(i) * frame.bucketNs)
                guard px >= -2 else { continue }
                path.addLine(to: CGPoint(x: px, y: y(Double(frame.envelope[i]))))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(.primary.opacity(0.12)))
        }

        let line = y(frame.threshold)
        var dashes = Path()
        dashes.move(to: CGPoint(x: 0, y: line))
        dashes.addLine(to: CGPoint(x: size.width, y: line))
        context.stroke(dashes, with: .color(.accentColor.opacity(0.55)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

        // Onsets: a spike whose alpha decays with age, so a burst reads as a
        // burst and an old tap fades out instead of vanishing.
        for onset in frame.onsets {
            guard onset.tNs >= startNs else { continue }
            let age = Double(frame.nowNs - onset.tNs) / 1_000_000_000
            let alpha = max(0, 1 - age / MonitorStore.window)
            let px = x(onset.tNs)
            let top = y(onset.strength)
            let bar = Path(CGRect(x: px - 1, y: top, width: 2, height: size.height - top))
            let color: Color = onset.suppressedByGate ? .secondary : .accentColor
            context.fill(bar,
                         with: .color(color.opacity(alpha * (onset.suppressedByGate ? 0.5 : 0.95))))
        }

        // Triggers.
        for t in frame.triggers where t >= startNs {
            let age = Double(frame.nowNs - t) / 1_000_000_000
            let alpha = max(0, 1 - age / MonitorStore.window)
            let px = x(t)
            context.fill(Path(CGRect(x: px - 1.5, y: 0, width: 3, height: size.height)),
                         with: .color(.accentColor.opacity(alpha * 0.35)))
            context.fill(Path(ellipseIn: CGRect(x: px - 3.5, y: 3, width: 7, height: 7)),
                         with: .color(.accentColor.opacity(alpha)))
        }
    }
}

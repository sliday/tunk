import AppKit
import SwiftUI
import TunkCore

/// Pulls one snapshot per display refresh. The sensor runs at 796 Hz; this runs
/// at 60–120 Hz and only while the panel is on screen. Nothing here touches the
/// detector directly.
final class TapMonitorModel: ObservableObject {
    @Published private(set) var frame = MonitorSnapshot()
    /// Slowly-decaying ceiling so the trace auto-scales without flickering.
    @Published private(set) var scale: Float = 0.05

    private var timer: Timer?
    private weak var engine: Engine?

    /// Seconds of history drawn.
    static let window: Double = 3.5

    func start(engine: Engine) {
        self.engine = engine
        guard timer == nil else { return }
        let fps = min(max(NSScreen.main?.maximumFramesPerSecond ?? 60, 30), 120)
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

    deinit { timer?.invalidate() }

    private func pull() {
        guard let engine else { return }
        let snap = engine.snapshot()
        let peak = snap.envelope.max() ?? 0
        scale = max(peak, scale * 0.97, 0.02)
        frame = snap
    }
}

struct TapMonitorView: View {
    @ObservedObject var model: TapMonitorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var armed: Bool

    private var gateActive: Bool {
        guard let last = model.frame.gateSpans.last else { return false }
        return model.frame.nowNs <= last.upperBound
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                Canvas(rendersAsynchronously: false) { context, size in
                    draw(context: &context, size: size)
                }
                .frame(height: 118)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                )
                .clipShape(RoundedRectangle(cornerRadius: Metrics.controlRadius,
                                            style: .continuous))
                .accessibilityLabel("Tap monitor")
                .accessibilityValue(gateActive ? "Gate suppressing onsets" : "Gate open")

                gatePill
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            numbers
            legend
        }
    }

    /// Everything here is in g, the same unit the detector thresholds in.
    private var numbers: some View {
        HStack(spacing: 18) {
            Readout(label: "envelope, g", value: format(model.frame.envelope.last ?? 0))
            Readout(label: "threshold, g", value: format(Float(model.frame.threshold)),
                    accent: .accentColor)
            Readout(label: "noise floor, g", value: format(Float(model.frame.noiseFloor)))
            Readout(label: "onsets, 3.5 s", value: "\(model.frame.onsets.count)")
        }
    }

    private func format(_ value: Float) -> String {
        String(format: "%.3f", value)
    }

    private var gatePill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(gateActive ? Color.orange : Color.green)
                .frame(width: 6, height: 6)
            Text(gateActive ? "SUPPRESSING" : "GATE OPEN")
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(gateActive ? Color.orange : Color.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
        )
        .opacity(armed ? 1 : 0.35)
        .tunkAnimation(.tunkSnappy, value: gateActive, reduceMotion: reduceMotion)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            swatch(Color.accentColor, "onset")
            swatch(Color.secondary.opacity(0.6), "suppressed")
            swatch(Color.orange.opacity(0.35), "gate window")
            Spacer()
            Text("3.5 s")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 8, height: 3)
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    // MARK: - drawing

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let frame = model.frame
        let windowNs = Int64(TapMonitorModel.window * 1_000_000_000)
        let startNs = frame.nowNs - windowNs
        guard windowNs > 0 else { return }

        func x(_ tNs: Int64) -> CGFloat {
            CGFloat(Double(tNs - startNs) / Double(windowNs)) * size.width
        }

        // Gate windows first, behind everything.
        for span in frame.gateSpans {
            let x0 = x(max(span.lowerBound, startNs))
            let x1 = x(min(span.upperBound, frame.nowNs))
            guard x1 > x0 else { continue }
            context.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)),
                         with: .color(.orange.opacity(0.16)))
        }

        // One vertical scale in g for everything: the trace, the onset spikes
        // and the threshold line. Headroom so a hard tap does not clip flat.
        let scale = CGFloat(max(Double(model.scale), frame.threshold * 2, 1e-4))
        let usable = size.height * 0.94
        func y(_ value: Double) -> CGFloat {
            size.height - min(CGFloat(value) / scale, 1) * usable
        }

        let line = y(frame.threshold)
        var dashes = Path()
        dashes.move(to: CGPoint(x: 0, y: line))
        dashes.addLine(to: CGPoint(x: size.width, y: line))
        context.stroke(dashes, with: .color(.accentColor.opacity(0.55)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        context.draw(Text("threshold").font(.system(size: 9))
            .foregroundColor(.secondary.opacity(0.8)),
                     at: CGPoint(x: 34, y: max(line - 8, 7)))

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

        // Onsets: a spike whose alpha decays with age, so a burst reads as a
        // burst and an old tap fades out instead of vanishing.
        for onset in frame.onsets {
            guard onset.tNs >= startNs else { continue }
            let age = Double(frame.nowNs - onset.tNs) / 1_000_000_000
            let alpha = max(0, 1 - age / TapMonitorModel.window)
            let px = x(onset.tNs)
            let top = y(onset.strength)
            let bar = Path(CGRect(x: px - 1, y: top, width: 2, height: size.height - top))
            let color: Color = onset.suppressedByGate ? .secondary : .accentColor
            context.fill(bar, with: .color(color.opacity(alpha * (onset.suppressedByGate ? 0.5 : 0.95))))
        }

        // Triggers.
        for t in frame.triggers where t >= startNs {
            let age = Double(frame.nowNs - t) / 1_000_000_000
            let alpha = max(0, 1 - age / TapMonitorModel.window)
            let px = x(t)
            context.fill(Path(CGRect(x: px - 1.5, y: 0, width: 3, height: size.height)),
                         with: .color(.accentColor.opacity(alpha * 0.35)))
            context.fill(Path(ellipseIn: CGRect(x: px - 3.5, y: 3, width: 7, height: 7)),
                         with: .color(.accentColor.opacity(alpha)))
        }
    }
}

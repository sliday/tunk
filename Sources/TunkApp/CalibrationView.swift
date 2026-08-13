import SwiftUI
import TunkCore

/// "Tap ten times." Coupling between your knuckle and the chassis changes with
/// the model, the surface and how hard you hit it, so the threshold comes from
/// the user's own distribution rather than a number we shipped.
struct CalibrationView: View {
    @ObservedObject var engine: Engine
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Phase = .collecting
    @State private var strengths: [Double] = []
    @State private var suppressed = 0
    @State private var result: CalibrationResult?
    @State private var revealed = false
    @State private var poll: Timer?

    private static let target = 10

    enum Phase: Equatable { case collecting, review, failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch phase {
            case .collecting: collecting
            case .review: review
            case .failed: failed
            }
            footer
        }
        .padding(Metrics.cardPadding + 4)
        .frame(width: 420)
        .onAppear(perform: begin)
        .onDisappear(perform: teardown)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Learn my tap")
                .font(.system(size: 15, weight: .semibold))
            Text(phase == .collecting
                 ? "Double-tap the palm rest ten times, the way you actually will. "
                 + "Rest your hands away from the keyboard between taps."
                 : "Here is what Tunk measured.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - collecting

    private var collecting: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<Self.target, id: \.self) { index in
                    Circle()
                        .fill(index < strengths.count ? Color.accentColor
                              : Color.primary.opacity(0.12))
                        .frame(width: 12, height: 12)
                        .scaleEffect(index < strengths.count ? 1 : 0.72)
                        .tunkAnimation(.tunkSnappy, value: strengths.count,
                                       reduceMotion: reduceMotion)
                }
                Spacer()
                Text("\(strengths.count) / \(Self.target)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 24)

            if suppressed > 0 {
                Label("\(suppressed) tap\(suppressed == 1 ? "" : "s") ignored — "
                      + "the gate saw keyboard or trackpad activity.",
                      systemImage: "hand.raised")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }

            if !engine.status.isArmed {
                Label("The sensor is not running. Enable detection first.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .tunkAnimation(.tunkSnappy, value: suppressed > 0, reduceMotion: reduceMotion)
    }

    // MARK: - review

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result {
                HStack(spacing: 18) {
                    Readout(label: "weakest tap", value: format(result.weakestStrength),
                            accent: .primary)
                    Readout(label: "median", value: format(result.medianStrength),
                            accent: .primary)
                    Readout(label: "threshold", value: format(result.threshold),
                            accent: .accentColor)
                    Readout(label: "margin",
                            value: String(format: "%.2f×", result.margin),
                            accent: result.margin < TapCalibration.comfortableMargin
                                ? .orange : .primary)
                }
                .opacity(revealed ? 1 : 0)
                .tunkAnimation(.tunkSnappy, value: revealed, reduceMotion: reduceMotion)
            }
            distribution
                .opacity(revealed ? 1 : 0)
                .tunkAnimation(.tunkSnappy.delay(Metrics.stagger), value: revealed,
                               reduceMotion: reduceMotion)
            Text(verdict)
                .font(.system(size: 11))
                .foregroundStyle(warned ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(revealed ? 1 : 0)
                .tunkAnimation(.tunkSnappy.delay(Metrics.stagger * 2), value: revealed,
                               reduceMotion: reduceMotion)
        }
    }

    private var warned: Bool {
        guard let result else { return false }
        return result.noiseLimited || result.margin < TapCalibration.comfortableMargin
    }

    private var verdict: String {
        guard let result else { return "" }
        if result.noiseLimited {
            return "This surface is noisy enough that the noise floor, not your tap, is "
                + "setting the bar. Tunk will still work, but expect to tap firmly. A hard "
                + "desk gives a better result than a lap or a cushion."
        }
        if result.margin < TapCalibration.comfortableMargin {
            return String(format: "Your weakest tap clears the bar by only %.2f×. That will "
                          + "work, but a light tap may be missed. Redo it hitting a little "
                          + "harder if that bothers you.", result.margin)
        }
        return "Every tap clears the line with room to spare. If one bar is much taller than "
            + "the rest you probably hit the deck instead of the palm rest."
    }

    private var distribution: some View {
        let sorted = strengths.sorted()
        let derived = result?.threshold
        let top = max(sorted.last ?? 1, derived ?? 1) * 1.15
        return ZStack(alignment: .bottomLeading) {
            GeometryReader { geo in
                let unit = geo.size.height / CGFloat(max(top, 1e-6))
                ZStack(alignment: .bottomLeading) {
                    if let derived {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.55))
                            .frame(height: 1)
                            .offset(y: -CGFloat(derived) * unit)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(Array(sorted.enumerated()), id: \.offset) { index, value in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Color.accentColor.opacity(0.75))
                                .frame(height: max(CGFloat(value) * unit, 2))
                                .scaleEffect(y: revealed ? 1 : 0.05, anchor: .bottom)
                                .tunkAnimation(.tunkSnappy.delay(Double(index) * 0.02),
                                               value: revealed, reduceMotion: reduceMotion)
                        }
                    }
                }
            }
        }
        .frame(height: 76)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Metrics.controlRadius + 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("That did not give a clean distribution.")
                .font(.system(size: 12, weight: .medium))
            Text("Tunk needs ten taps of roughly the same strength. Try again on a firm "
                 + "surface, hitting the palm rest with a knuckle.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Cancel") { finish(commit: nil) }
                .buttonStyle(TunkButtonStyle())
            Spacer()
            Button("Start over", action: restart)
                .buttonStyle(TunkButtonStyle())
            if phase == .review {
                Button("Use this threshold") { finish(commit: result?.threshold) }
                    .buttonStyle(TunkButtonStyle(prominent: true))
            }
        }
    }

    // MARK: - flow

    private func begin() {
        engine.beginCalibration()
        restart()
    }

    private func restart() {
        engine.clearCalibrationSamples()
        strengths = []
        suppressed = 0
        result = nil
        revealed = false
        phase = .collecting
        poll?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { _ in
            step()
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    private func step() {
        let progress = engine.calibrationProgress()
        suppressed = progress.suppressed
        strengths = Array(progress.strengths.prefix(Self.target))
        guard strengths.count >= Self.target else { return }
        poll?.invalidate()
        poll = nil
        result = TapCalibration.calibrate(tapStrengths: strengths,
                                          noiseFloor: progress.noiseFloor)
        phase = result == nil ? .failed : .review
        // One genuine one-shot sequence: numbers, then bars, then the note.
        DispatchQueue.main.async { revealed = true }
    }

    private func finish(commit threshold: Double?) {
        poll?.invalidate()
        poll = nil
        engine.endCalibration(commit: threshold)
        onClose()
    }

    private func teardown() {
        poll?.invalidate()
        poll = nil
        engine.endCalibration(commit: nil)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

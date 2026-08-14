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
    /// Completed gestures, not loose onsets. The dots used to count onsets while
    /// the copy asked for ten double-taps, so the step ended halfway through what
    /// it had just asked for.
    @State private var gestures: [(strengths: [Double], intervalNs: Int64)] = []

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
                        .fill(index < gestures.count ? Color.accentColor
                              : Color.primary.opacity(0.12))
                        .frame(width: 12, height: 12)
                        .scaleEffect(index < gestures.count ? 1 : 0.72)
                        .tunkAnimation(.tunkSnappy, value: gestures.count,
                                       reduceMotion: reduceMotion)
                }
                Spacer()
                Text("\(gestures.count) / \(Self.target)")
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
                    Readout(label: scaledBySensitivity ? "threshold in force" : "threshold",
                            value: format(thresholdInForce ?? result.threshold),
                            accent: .accentColor)
                    Readout(label: "margin",
                            value: String(format: "%.2f×", marginInForce),
                            accent: marginInForce < TapCalibration.comfortableMargin
                                ? .orange : .primary)
                }
                .opacity(revealed ? 1 : 0)
                .tunkAnimation(.tunkSnappy, value: revealed, reduceMotion: reduceMotion)

                // Said out loud rather than folded into one number: the panel's
                // sensitivity slider multiplies whatever this step derives, so
                // the bar shown above is not the bar that was measured.
                if scaledBySensitivity {
                    Text(String(format: "Your sensitivity slider is at %.2f×, so the %.3f g "
                                + "measured from these taps runs as %.3f g. Set sensitivity "
                                + "back to 1.00× to run exactly what was measured.",
                                engine.calibrationSensitivity, result.threshold,
                                thresholdInForce ?? result.threshold))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
            if let ring = ringNote {
                Text(ring)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(ringIsLoud ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(revealed ? 1 : 0)
                    .tunkAnimation(.tunkSnappy.delay(Metrics.stagger * 3), value: revealed,
                                   reduceMotion: reduceMotion)
            }
            if let timing = timingNote {
                Text(timing)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(result?.interTapClamped == true
                                     ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(revealed ? 1 : 0)
                    .tunkAnimation(.tunkSnappy.delay(Metrics.stagger * 3), value: revealed,
                                   reduceMotion: reduceMotion)
            }
        }
    }

    private var ringIsLoud: Bool {
        (result?.ringToStrike ?? 0) > TapCalibration.noisyRingRatio
    }

    /// How loudly this surface rings, and what to do about it.
    ///
    /// Worth saying out loud because it is the property that actually predicts
    /// whether a surface works, and it is not the one a user would guess. Across
    /// four lap recordings the tap amplitude, the noise floor and the decay time
    /// were all but identical, and signal-to-noise ran backwards — the session
    /// that detected every gesture had the WORST SNR. What tracked detection was
    /// how much of the first strike was still ringing when the second arrived.
    private var ringNote: String? {
        guard let ratio = result?.ringToStrike else { return nil }
        if ratio > TapCalibration.noisyRingRatio {
            return String(format: "This surface rings loudly: %.0f %% of each tap is still "
                          + "sounding when the second one lands, against %.0f %% on a surface "
                          + "that works well. Your second tap has to be heard over the first "
                          + "one's echo, so expect some misses. Resting an arm on the case "
                          + "while you tap is a common cause — try lifting it.",
                          ratio * 100, 40.0)
        }
        return String(format: "This surface settles quickly: %.0f %% of each tap is still "
                      + "sounding when the second lands. That is the range where Tunk is "
                      + "most reliable.", ratio * 100)
    }

    /// What the learned rhythm means, in the two cases that differ for the user.
    ///
    /// When the fit is clamped they are being told something real: their gesture
    /// is slower than the responsiveness budget allows, so some of their own
    /// double-taps will be read as two singles. That is a trade between latency
    /// and reliability, and it is theirs to make — the alternative is silently
    /// cutting the window and letting them wonder why Tunk misses them.
    private var timingNote: String? {
        guard let result, let window = result.interTapNs,
              let p10 = result.interTapP10Ns, let p90 = result.interTapP90Ns else { return nil }
        let ms = { (ns: Int64) in Int((Double(ns) / 1e6).rounded()) }
        if result.interTapClamped {
            return String(format: "Your two taps land %d–%d ms apart, which is slower than the "
                          + "%d ms Tunk can wait and still fire promptly. The window is set to "
                          + "%d ms, so your slowest double-taps may read as two singles. "
                          + "Tapping a little quicker fixes it.",
                          ms(p10), ms(p90),
                          ms(TapCalibration.latencySafeWindowNs), ms(window))
        }
        return String(format: "Your two taps land %d–%d ms apart, so Tunk will wait %d ms "
                      + "before acting. That wait is the delay you will feel.",
                      ms(p10), ms(p90), ms(window))
    }

    /// The bar the detector will run once this is committed. Calibration
    /// measures with sensitivity held at 1.0, but `effectiveThreshold` is
    /// `calibratedThreshold * sensitivity`, so a user who has moved that slider
    /// gets a different number than the one this step derived. Same formula the
    /// detector uses: the calibrated term, or the noise floor, whichever wins.
    private var thresholdInForce: Double? {
        guard let result else { return nil }
        let tuning = DSPTuning.default
        return max(result.threshold * engine.calibrationSensitivity,
                   max(tuning.noiseSnrMultiple * result.noiseFloor, tuning.minThresholdG))
    }

    /// `weakest tap / threshold in force`. `CalibrationResult.margin` is
    /// measured against the derived threshold, which is not what runs.
    private var marginInForce: Double {
        guard let result, let bar = thresholdInForce, bar > 0 else { return .infinity }
        return result.weakestStrength / bar
    }

    private var scaledBySensitivity: Bool {
        abs(engine.calibrationSensitivity - 1.0) > 0.001
    }

    private var warned: Bool {
        guard let result else { return false }
        return result.noiseLimited || marginInForce < TapCalibration.comfortableMargin
    }

    private var verdict: String {
        guard let result else { return "" }
        if result.noiseLimited {
            return "This surface is noisy enough that the noise floor, not your tap, is "
                + "setting the bar. Tunk will still work, but expect to tap firmly. A hard "
                + "desk gives a better result than a lap or a cushion."
        }
        if marginInForce < TapCalibration.comfortableMargin {
            return String(format: "Your weakest tap clears the bar by only %.2f×. That will "
                          + "work, but a light tap may be missed. Redo it hitting a little "
                          + "harder if that bothers you.", marginInForce)
        }
        return "Every tap clears the line with room to spare. If one bar is much taller than "
            + "the rest you probably hit the deck instead of the palm rest."
    }

    private var distribution: some View {
        let sorted = strengths.sorted()
        // The line is drawn where the detector will put it, not where the
        // derivation put it, so a bar that looks clear of it really is.
        let derived = thresholdInForce
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
                Button("Use this") { finish(commit: result) }
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
        gestures = []
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
        var runs = TapCalibration.gestures(onsetTimesNs: progress.onsetTimesNs,
                                           strengths: progress.strengths)
        // The newest run is provisional: a second tap may still be on its way,
        // and counting it now would score a half-finished gesture as done and
        // learn an interval of zero from it.
        if let last = progress.onsetTimesNs.last,
           engine.nowNs() - last < TapCalibration.gestureSpanNs, !runs.isEmpty {
            runs.removeLast()
        }
        gestures = Array(runs.prefix(Self.target))
        strengths = gestures.flatMap(\.strengths)
        guard gestures.count >= Self.target else { return }
        poll?.invalidate()
        poll = nil
        result = TapCalibration.calibrate(gestures: gestures,
                                          noiseFloor: progress.noiseFloor,
                                          ringRatios: progress.ringRatios)
        phase = result == nil ? .failed : .review
        // One genuine one-shot sequence: numbers, then bars, then the note.
        DispatchQueue.main.async { revealed = true }
    }

    private func finish(commit result: CalibrationResult?) {
        poll?.invalidate()
        poll = nil
        engine.endCalibration(commit: result)
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

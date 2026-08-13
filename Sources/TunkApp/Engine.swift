import AppKit
import Foundation
import TunkCore
import TunkEmit
import TunkIMU

/// What the menubar glyph and the status card show.
enum EngineStatus: Equatable {
    case off
    case running
    case sensorLost(String)
    case needsPermission

    var isArmed: Bool { self == .running }
}

/// One frame's worth of tap-monitor data. Copied out under the lock and handed
/// to the UI, so the drawing code never touches live detector state.
struct MonitorSnapshot {
    var nowNs: Int64 = 0
    /// Peak motion per bucket, oldest first. Display only — this is the app's
    /// own envelope, not the detector's statistic.
    var envelope: [Float] = []
    var bucketNs: Int64 = 1
    var startNs: Int64 = 0
    var onsets: [OnsetEvent] = []
    var triggers: [Int64] = []
    /// Half-open ranges during which the gate was suppressing onsets.
    var gateSpans: [ClosedRange<Int64>] = []
    /// The live bar, in g: `TapDetector.activeThreshold`.
    var threshold: Double = 0
    /// The detector's adaptive noise floor, in g.
    var noiseFloor: Double = 0
}

/// Owns the sensor, the detector, the input gate and the emitter, and is the
/// only thing that knows how they fit together.
///
/// Threading: samples arrive on `AccelSource`'s own queue and go straight into
/// the detector under `detectorLock`. Input events arrive on the main thread and
/// take the same lock. Everything the UI reads is either `@Published` on main or
/// copied out through `snapshot()`.
final class Engine: ObservableObject {
    @Published private(set) var status: EngineStatus = .off
    @Published private(set) var sampleRateHz: Double = 0
    @Published private(set) var triggerCount: Int = 0
    @Published private(set) var lastLatencyMs: Double?
    @Published private(set) var lastEmitError: String?
    @Published private(set) var permissions: PermissionState = .current()
    @Published private(set) var isCalibrating = false
    /// Straight from the emitter, so the panel can show that every key-down got
    /// its key-up rather than asserting it in a comment.
    @Published private(set) var emitStats = EmitStats()

    /// Fired on the main thread each time a gesture is confirmed, so the menubar
    /// can flash.
    var onTrigger: (() -> Void)?

    private let settings: AppSettings
    private let accel = AccelSource()
    private let emitter: HotkeyEmitter
    private var input: InputActivityMonitor?

    private let detectorLock = NSLock()
    private var detector: TapDetecting
    /// The same object as `detector`, kept typed so the monitor can read the
    /// envelope and the live threshold without a cast per sample.
    private var readout: TapDetector?

    /// Session epoch. Fixed for the life of the process so the monitor timeline
    /// survives a reacquire.
    private let epochNs: Int64 = MachClock.nowNanos()
    func nowNs() -> Int64 { MachClock.nowNanos() - epochNs }

    // Monitor ring: 4.27 s at 120 Hz, which is one bucket per drawn frame at
    // the fastest display this runs on. Finer buckets would cost redraw time
    // and show nothing extra.
    private static let bucketNs: Int64 = 1_000_000_000 / 120
    private static let bucketCount = 512
    private var ring = ContiguousArray<Float>(repeating: 0, count: Engine.bucketCount)
    private var ringBucket: Int64 = 0
    private var onsetLog: [OnsetEvent] = []
    private var triggerLog: [Int64] = []
    private var gateLog: [Int64] = []

    // Calibration.
    private var calibrationStrengths: [Double] = []
    private var calibrationSuppressed = 0
    private var configBeforeCalibration: DetectorConfig?
    /// Floor used while learning a tap, so weak taps still produce an onset to
    /// measure. Nothing fires while calibrating.
    static let calibrationFloor: Double = 0.02

    // Watchdog.
    private var tick: Timer?
    private var lastSampleCount: UInt64 = 0
    private var lastTickNs: Int64 = 0
    private var starvedTicks = 0
    private var reacquireBackoff = 1
    private var wantsRunning = false

    init(settings: AppSettings) {
        self.settings = settings
        let made = DetectorFactory.make(config: settings.config)
        self.detector = made
        self.readout = made as? TapDetector
        self.emitter = HotkeyEmitter(hotkey: settings.hotkey)

        settings.onConfigChange = { [weak self] config in self?.apply(config: config) }
        settings.onEnabledChange = { [weak self] on in self?.setEnabled(on) }
        settings.onHotkeyChange = { [weak self] spec in self?.emitter.hotkey = spec }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep),
                           name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake),
                           name: NSWorkspace.didWakeNotification, object: nil)

        tick = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.watchdog()
        }
        if let tick { RunLoop.main.add(tick, forMode: .common) }
    }

    deinit {
        tick?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        accel.stop()
        input?.stop()
    }

    // MARK: - lifecycle

    func setEnabled(_ on: Bool) {
        wantsRunning = on
        on ? start() : stop()
    }

    func refreshPermissions() {
        let now = PermissionState.current()
        if now != permissions { permissions = now }
        if wantsRunning, case .needsPermission = status, now.ready { start() }
    }

    private func start() {
        guard wantsRunning else { return }
        let perms = PermissionState.current()
        permissions = perms
        // Refuse to arm half-blind. A detector that cannot see keystrokes cannot
        // suppress typing, and typing false positives are the metric that
        // decides whether this app is worth running at all.
        guard perms.ready else {
            stopSensors()
            status = .needsPermission
            return
        }

        detectorLock.lock()
        detector.config = settings.config
        detector.reset()
        detectorLock.unlock()

        let monitor = InputActivityMonitor(epochNs: { [weak self] in self?.epochNs ?? 0 }) {
            [weak self] event in self?.feed(input: event)
        }
        monitor.start()
        input = monitor

        do {
            try accel.start(epochMachNs: epochNs) { [weak self] sample in
                self?.feed(sample: sample)
            }
            lastSampleCount = accel.snapshotStats().sampleCount
            starvedTicks = 0
            reacquireBackoff = 1
            status = .running
        } catch {
            status = .sensorLost(String(describing: error))
        }
    }

    private func stop() {
        stopSensors()
        status = .off
        sampleRateHz = 0
    }

    private func stopSensors() {
        accel.stop()
        input?.stop()
        input = nil
    }

    // MARK: - hot path

    private func feed(sample: AccelSample) {
        detectorLock.lock()
        let trigger = detector.ingest(sample: sample)
        let onsets = detector.drainOnsets()
        // The detector's own transient envelope, in g. Drawing that rather than
        // a second filter of our own keeps the trace, the onset spikes and the
        // threshold line in one coordinate system.
        recordEnvelope(tNs: sample.tNs, value: Float(readout?.envelope ?? 0))
        for onset in onsets { record(onset: onset) }
        if let trigger { record(trigger: trigger) }
        let calibrating = configBeforeCalibration != nil
        detectorLock.unlock()

        guard let trigger else { return }
        if calibrating { return }        // learning a tap must never fire a key

        var failure: String?
        var stats = EmitStats()
        do {
            stats = try emitter.emit(for: trigger)
        } catch {
            failure = error.localizedDescription
            stats = emitter.stats
        }
        // Measured after the post returns, so this is onset-to-key-out, not
        // onset-to-decision. The decision-only figure is what the harness scores.
        let latencyMs = Double(nowNs() - (trigger.tapOnsets.last ?? trigger.tNs)) / 1_000_000

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.triggerCount += 1
            self.lastLatencyMs = latencyMs
            self.lastEmitError = failure
            self.emitStats = stats
            self.onTrigger?()
        }
    }

    private func feed(input event: InputEvent) {
        detectorLock.lock()
        // `tNs` must not go backwards for the detector. Input is stamped from
        // the same mach timebase but device sample stamps trail arrival by a few
        // hundred microseconds, so a clamp is cheap insurance rather than a fudge.
        var e = event
        e.tNs = max(e.tNs, ringBucket * Engine.bucketNs)
        detector.ingest(input: e)
        if e.kind.gatesDetection { record(gate: e.tNs) }
        detectorLock.unlock()
    }

    // MARK: - monitor buffers (all called with the lock held)

    private func recordEnvelope(tNs: Int64, value: Float) {
        let bucket = tNs / Engine.bucketNs
        if bucket > ringBucket {
            let gap = Int(min(bucket - ringBucket, Int64(Engine.bucketCount)))
            for step in 1...gap {
                ring[Int((ringBucket + Int64(step)) % Int64(Engine.bucketCount))] = 0
            }
            ringBucket = bucket
        }
        let idx = Int(((bucket % Int64(Engine.bucketCount)) + Int64(Engine.bucketCount))
            % Int64(Engine.bucketCount))
        if value > ring[idx] { ring[idx] = value }
    }

    private func record(onset: OnsetEvent) {
        if onsetLog.count >= 256 { onsetLog.removeFirst(onsetLog.count - 255) }
        onsetLog.append(onset)
        guard configBeforeCalibration != nil else { return }
        if onset.suppressedByGate {
            calibrationSuppressed += 1
        } else {
            calibrationStrengths.append(onset.strength)
        }
    }

    private func record(trigger: Trigger) {
        if triggerLog.count >= 32 { triggerLog.removeFirst(triggerLog.count - 31) }
        triggerLog.append(trigger.tNs)
    }

    private func record(gate tNs: Int64) {
        if gateLog.count >= 256 { gateLog.removeFirst(gateLog.count - 255) }
        gateLog.append(tNs)
    }

    // MARK: - UI reads

    /// Copies one frame of monitor state. Called at display refresh, never at
    /// sample rate.
    func snapshot() -> MonitorSnapshot {
        let now = nowNs()
        let window = Int64(Engine.bucketCount) * Engine.bucketNs
        var out = MonitorSnapshot()
        out.nowNs = now
        out.bucketNs = Engine.bucketNs

        detectorLock.lock()
        // The bar an onset actually has to clear right now: the calibrated
        // absolute term, the adaptive noise term, or the floor, whichever wins.
        out.threshold = readout?.activeThreshold ?? settings.config.effectiveThreshold
        out.noiseFloor = readout?.noiseFloor ?? 0
        let newest = ringBucket
        var values = [Float](repeating: 0, count: Engine.bucketCount)
        for i in 0..<Engine.bucketCount {
            let bucket = newest - Int64(Engine.bucketCount - 1 - i)
            if bucket < 0 { continue }
            values[i] = ring[Int(bucket % Int64(Engine.bucketCount))]
        }
        out.envelope = values
        out.startNs = (newest - Int64(Engine.bucketCount - 1)) * Engine.bucketNs
        out.onsets = onsetLog.filter { $0.tNs >= now - window }
        out.triggers = triggerLog.filter { $0 >= now - window }
        let gateWindow = settings.config.gateWindowNs
        var spans: [ClosedRange<Int64>] = []
        for t in gateLog where t >= now - window {
            let span = t...(t + gateWindow)
            if var last = spans.last, last.lowerBound <= span.lowerBound,
               last.upperBound >= span.lowerBound {
                last = last.lowerBound...max(last.upperBound, span.upperBound)
                spans[spans.count - 1] = last
            } else {
                spans.append(span)
            }
        }
        out.gateSpans = spans
        detectorLock.unlock()
        return out
    }

    /// True while the gate is currently suppressing onsets. Mirrors the
    /// detector's own rule; display only.
    func gateArmed(at nowNs: Int64) -> Bool {
        detectorLock.lock()
        let last = gateLog.last ?? .min / 4
        detectorLock.unlock()
        return nowNs - last < settings.config.gateWindowNs
    }

    // MARK: - config

    private func apply(config: DetectorConfig) {
        detectorLock.lock()
        // Calibration owns the config while it runs; committing restores it.
        if configBeforeCalibration != nil {
            configBeforeCalibration = config
        } else {
            detector.config = config
        }
        detectorLock.unlock()
    }

    // MARK: - calibration

    func beginCalibration() {
        detectorLock.lock()
        guard configBeforeCalibration == nil else { detectorLock.unlock(); return }
        configBeforeCalibration = settings.config
        var probe = settings.config
        probe.calibratedThreshold = nil
        probe.defaultThreshold = Engine.calibrationFloor
        probe.sensitivity = 1.0
        detector.config = probe
        detector.reset()
        calibrationStrengths.removeAll(keepingCapacity: true)
        calibrationSuppressed = 0
        detectorLock.unlock()
        isCalibrating = true
    }

    /// Strengths gathered so far, plus how many onsets the gate threw away —
    /// the user needs to know when their resting hand is eating their taps —
    /// plus the noise floor the calibration has to clear.
    func calibrationProgress() -> (strengths: [Double], suppressed: Int, noiseFloor: Double) {
        detectorLock.lock(); defer { detectorLock.unlock() }
        return (calibrationStrengths, calibrationSuppressed, readout?.noiseFloor ?? 0)
    }

    /// Fires the configured combination on demand, for the panel's test button.
    @discardableResult
    func testEmit() throws -> EmitStats {
        let stats = try emitter.emit(settings.hotkey)
        emitStats = stats
        return stats
    }

    func clearCalibrationSamples() {
        detectorLock.lock()
        calibrationStrengths.removeAll(keepingCapacity: true)
        calibrationSuppressed = 0
        detectorLock.unlock()
    }

    /// Ends the learn step. `commit` writes the derived threshold into the one
    /// `DetectorConfig` everything reads.
    @discardableResult
    func endCalibration(commit threshold: Double?) -> Bool {
        detectorLock.lock()
        guard var restored = configBeforeCalibration else { detectorLock.unlock(); return false }
        configBeforeCalibration = nil
        if let threshold { restored.calibratedThreshold = threshold }
        detector.config = restored
        detector.reset()
        detectorLock.unlock()

        isCalibrating = false
        settings.config = restored          // persists, and hands the same struct back
        return threshold != nil
    }

    // MARK: - sleep, wake, and a stuck sensor

    @objc private func willSleep() {
        guard wantsRunning else { return }
        stopSensors()
        status = .off
    }

    @objc private func didWake() {
        guard wantsRunning else { return }
        // The SPU device can come back a moment after the display does. One
        // delayed attempt, then the watchdog owns retries.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.wantsRunning else { return }
            self.start()
        }
    }

    private func watchdog() {
        let stats = accel.snapshotStats()
        let delta = stats.sampleCount >= lastSampleCount ? stats.sampleCount - lastSampleCount : 0
        lastSampleCount = stats.sampleCount
        let now = nowNs()
        let elapsed = max(Double(now - lastTickNs) / 1_000_000_000, 0.001)
        lastTickNs = now
        if case .running = status {
            sampleRateHz = Double(delta) / elapsed
        } else if sampleRateHz != 0 {
            sampleRateHz = 0
        }

        if permissions != PermissionState.current() { permissions = .current() }
        guard wantsRunning else { return }

        switch status {
        case .running where delta == 0:
            starvedTicks += 1
            if starvedTicks >= 2 {
                status = .sensorLost("no samples for \(starvedTicks) s")
                reacquireBackoff = 1
            }
        case .running:
            starvedTicks = 0
        case .sensorLost:
            // Bounded backoff: 1, 2, 4 … 32 s. Never a spin.
            starvedTicks += 1
            if starvedTicks >= reacquireBackoff {
                starvedTicks = 0
                reacquireBackoff = min(reacquireBackoff * 2, 32)
                stopSensors()
                start()          // re-opens on the same epoch; sets the next status
            }
        case .needsPermission:
            if PermissionState.current().ready { start() }
        case .off:
            break
        }
    }
}

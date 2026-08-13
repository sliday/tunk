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

/// Carries a weak `Engine` across a `@Sendable` boundary. `Engine` is not
/// `Sendable` and must not pretend to be; this box only moves the reference,
/// and every read of it happens on the main thread.
private final class WeakEngineRef: @unchecked Sendable {
    weak var engine: Engine?
    init(_ engine: Engine) { self.engine = engine }
}

/// Owns the sensor, the detector, the input gate and the action runner, and is
/// the only thing that knows how they fit together.
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
    @Published private(set) var permissions: PermissionState = .current()
    @Published private(set) var isCalibrating = false
    /// Straight from the action runner, so the panel can show that every
    /// key-down got its key-up rather than asserting it in a comment, and can
    /// show a shortcut's dispatch and completion latencies side by side.
    @Published private(set) var actionStats = ActionStats()

    /// The Shortcuts library as last listed, for the panel's dropdown. Refreshed
    /// when the panel opens, on wake, and on a slow timer — never by running
    /// anything.
    @Published private(set) var shortcutNames: [String] = []
    /// False when `shortcuts list` has not come back cleanly. The panel needs
    /// the distinction: no Shortcuts and no readable Shortcuts are different
    /// problems with different fixes.
    @Published private(set) var shortcutsReadable = false

    /// A bound Shortcut that no longer resolves. Passive by design — the
    /// menubar glyph and the panel show it, and nothing ever raises a dialog.
    var brokenBinding: BrokenBinding? { actionStats.brokenBinding }

    /// The last gesture the detector closed without firing, because nothing is
    /// bound to its tap count. Shown in the monitor so a user who taps three
    /// times sees "3 taps, nothing bound" instead of silence and concludes the
    /// app is broken.
    @Published private(set) var lastUnboundGesture: (tapCount: Int, atNs: Int64)?

    /// What the detector is actually running, after incoherent combinations are
    /// clamped. The panel reads this, not `settings.config` — a number the user
    /// typed that is not the number in force has to be visible as both.
    var effectiveConfig: DetectorConfig {
        detectorLock.lock(); defer { detectorLock.unlock() }
        return readout?.effectiveConfig ?? settings.config.madeCoherent()
    }

    /// What the clamp changed and why, in words the panel can print verbatim.
    var coherenceIssues: [DetectorConfig.CoherenceIssue] { settings.config.coherenceIssues }

    /// Fired on the main thread each time a gesture is confirmed, so the menubar
    /// can flash.
    var onTrigger: (() -> Void)?

    private let settings: AppSettings
    private let accel = AccelSource()
    private let runner: ActionRunner
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
    private var catalogTicks = 0

    init(settings: AppSettings) {
        self.settings = settings
        let made = DetectorFactory.make(config: settings.config,
                                        armedTapCounts: settings.config.armedTapCounts)
        self.detector = made
        self.readout = made as? TapDetector
        self.runner = ActionRunner(bindings: settings.bindings)

        settings.onConfigChange = { [weak self] config in self?.apply(config: config) }
        settings.onEnabledChange = { [weak self] on in self?.setEnabled(on) }
        settings.onBindingsChange = { [weak self] bindings in
            self?.runner.bindings = bindings
            // The user has just chosen; re-check against the list right away so
            // a name that is already stale is called out before the first tap.
            self?.refreshShortcutCatalog()
        }

        // A shortcut reports back long after the tap that started it, from the
        // spawner's queue. This is the only path by which a failed shortcut
        // reaches the panel, so it must not be dropped. The box exists so the
        // engine is dereferenced on the main thread and nowhere else — its
        // `@Published` properties are not thread-safe, which is the whole
        // reason every write in this file hops first.
        let box = WeakEngineRef(self)
        runner.onChange = { stats in
            DispatchQueue.main.async { box.engine?.actionStats = stats }
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep),
                           name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake),
                           name: NSWorkspace.didWakeNotification, object: nil)

        tick = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.watchdog()
        }
        if let tick { RunLoop.main.add(tick, forMode: .common) }
        refreshShortcutCatalog()
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
        arm(for: settings.config)
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
        // Groups that closed without firing. Draining is not optional here: the
        // log is bounded, and an undrained one would just discard the oldest.
        let unbound = readout?.drainGroups().last { !$0.fired }
        let calibrating = configBeforeCalibration != nil
        detectorLock.unlock()

        if let unbound, !calibrating {
            let seen = (tapCount: unbound.tapCount, atNs: unbound.tNs)
            DispatchQueue.main.async { [weak self] in self?.lastUnboundGesture = seen }
        }

        guard let trigger else { return }
        if calibrating { return }        // learning a tap must never fire a key

        // The runner picks the action bound to `trigger.tapCount`. Nothing bound
        // to that count is a quiet no-op, which is what lets triple tap stay
        // unwired and single tap stay unbound without either being a failure.
        //
        // Throws only on the hotkey path, and the runner has already put the
        // text in `stats.lastErrorText`; catching it here keeps it off the
        // sensor thread's call stack.
        _ = try? runner.run(for: trigger)

        // Measured after the runner returns, so this is onset-to-handoff: the
        // keystroke is out, or the shortcut has been handed to its own queue.
        // What a shortcut then does with its own time is `ActionStats`'s
        // completion latency and is not part of this number.
        let latencyMs = Double(nowNs() - (trigger.tapOnsets.last ?? trigger.tNs)) / 1_000_000

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.triggerCount += 1
            self.lastLatencyMs = latencyMs
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
            arm(for: config)
        }
        detectorLock.unlock()
    }

    /// Mirrors the armed counts onto the detector. Called with the lock held.
    ///
    /// The detector treats a nil `armedTapCounts` as "use `tapCountToFire`",
    /// which reads the *lowest* armed count — so leaving it nil with single and
    /// double both bound would arm single alone. Setting it explicitly keeps
    /// `config.armedTapCounts` the single source of truth for what fires.
    private func arm(for config: DetectorConfig) {
        readout?.armedTapCounts = config.armedTapCounts
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

    /// Runs one row's action once, on demand, for that row's Test button.
    ///
    /// This and a real tap are the only two things in Tunk that may run a user's
    /// Shortcut. Nothing probes, validates, warms up or benchmarks one — the
    /// stale-name check reads `shortcuts list` and never runs anything.
    @discardableResult
    func testAction(tapCount: Int) throws -> ActionStats {
        let stats = try runner.run(settings.bindings[tapCount], tapCount: tapCount)
        actionStats = stats
        return stats
    }

    /// Re-lists the Shortcuts library and re-checks every bound name against it.
    /// Read-only, ~10 ms, and it runs nothing. Off the main thread because
    /// spawning a process on it, however briefly, is rude.
    func refreshShortcutCatalog() {
        let box = WeakEngineRef(self)
        DispatchQueue.global(qos: .utility).async {
            let listing = ShortcutsCatalog.refreshListing()
            DispatchQueue.main.async {
                guard let engine = box.engine else { return }
                engine.shortcutNames = listing.names
                engine.shortcutsReadable = listing.succeeded
                engine.runner.revalidateShortcutBindings()
            }
        }
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
        arm(for: restored)
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
        // Unconditional: the library may have changed while the lid was shut,
        // and this costs a read-only listing whether or not detection is armed.
        refreshShortcutCatalog()
        guard wantsRunning else { return }
        // The SPU device can come back a moment after the display does. One
        // delayed attempt, then the watchdog owns retries.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.wantsRunning else { return }
            self.start()
        }
    }

    /// Ticks between Shortcuts re-listings. 60 s against a ~10 ms read-only
    /// listing is free, and it means a rename is usually caught before the user
    /// taps rather than after.
    private static let catalogRefreshTicks = 60

    private func watchdog() {
        catalogTicks += 1
        if catalogTicks >= Engine.catalogRefreshTicks {
            catalogTicks = 0
            refreshShortcutCatalog()
        }

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

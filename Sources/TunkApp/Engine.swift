import AppKit
import Foundation
import TunkCore
import TunkFormat
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

    /// Set when the most recent gesture fired but its action threw. Distinct
    /// from `brokenBinding`, which is a static problem with what is configured;
    /// this is a live failure of an action that looked fine.
    @Published private(set) var lastActionFailed = false

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
    /// The front end the LIVE detector is running, read from the detector rather
    /// than from settings. The panel shows this because the harness does: a run
    /// on a non-shipped front end prints a warning line, and an owner with an
    /// experimental switch on deserves the same. It is also the only way to see
    /// that a switch reached the detector at all.
    var liveTuning: DSPTuning {
        detectorLock.lock(); defer { detectorLock.unlock() }
        return readout?.tuning ?? settings.tuning
    }

    var effectiveConfig: DetectorConfig {
        detectorLock.lock(); defer { detectorLock.unlock() }
        return readout?.effectiveConfig ?? settings.effectiveConfig.madeCoherent()
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
    /// Absolute mach nanoseconds at which `nowNs()` reads zero. A recorder needs
    /// it to write `epoch_mach_ns`, which is what ties a session's timestamps to
    /// this machine's clock.
    var epochMachNs: Int64 { epochNs }

    /// Whether the input monitor is live. A session recorded without it cannot
    /// replay the suppression gate, so a recorder has to state which it got
    /// rather than assume.
    var inputTapActive: Bool { input?.isRunning ?? false }

    // Monitor ring: 4.27 s at 120 Hz, which is one bucket per drawn frame at
    // the fastest display this runs on. Finer buckets would cost redraw time
    // and show nothing extra.
    private static let bucketNs: Int64 = 1_000_000_000 / 120
    private static let bucketCount = 512
    private var ring = ContiguousArray<Float>(repeating: 0, count: Engine.bucketCount)
    private var ringBucket: Int64 = 0
    private var onsetLog: [OnsetEvent] = []

    /// Writes the seconds around tap-shaped transients to disk during ordinary
    /// use. Nil unless switched on. See `PassiveCapture` for what its output can
    /// and cannot be used to measure.
    var passive: PassiveCapture?

    /// Every confirmed gesture, for the live acceptance test. Set only by
    /// `Diagnostics.acceptance`; nil in normal operation, so it costs a nil
    /// check per trigger and nothing per sample.
    var onTriggerForTesting: ((Trigger) -> Void)?

    /// Writes the live stream to a FORMAT.md session directory. Nil in normal
    /// operation, and set only by `Diagnostics.acceptance --record`, so it costs
    /// one nil check per sample and nothing otherwise.
    ///
    /// Read under `detectorLock` on the sensor thread, so it is set under the
    /// same lock rather than assigned across threads.
    private var recorder: AcceptanceRecorder?
    func setRecorder(_ r: AcceptanceRecorder?) {
        detectorLock.lock()
        recorder = r
        detectorLock.unlock()
    }

    private var triggerLog: [Int64] = []
    private var gateLog: [Int64] = []

    // Calibration.
    private var calibrationStrengths: [Double] = []
    /// Onset times as well as strengths, so calibration can learn the user's
    /// gesture *rhythm* and not just how hard they hit. Same order as
    /// `calibrationStrengths`.
    private var calibrationOnsetTimes: [Int64] = []
    /// Ring-to-strike ratio per calibration onset: the loudest envelope 60-100 ms
    /// after the strike, over the strike's own peak. Measured because it is what
    /// actually predicts whether a surface will work — see
    /// `CalibrationResult.ringToStrike`.
    private var calibrationRingRatios: [Double] = []
    /// The onset still inside its 60-100 ms measuring window, if any.
    private var ringPending: (tNs: Int64, peak: Double, ring: Double)?
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
    /// Consecutive healthy watchdog ticks. Gates the backoff reset; see the
    /// watchdog switch.
    private var healthyTicks = 0
    /// Every call into `AccelSource` runs here: off the main thread, and one at
    /// a time.
    ///
    /// Off main because `IOHIDEventSystemClientScheduleWithDispatchQueue` was
    /// measured hanging indefinitely on repeated stop/start — intermittently, at
    /// cycle 8 or 10 of a tight loop, with every earlier cycle taking 0.00 s. It
    /// reproduces with and without the client release, so it is not that. See
    /// notes/OPEN_ITEMS. The watchdog that reacquires is a main-thread Timer, so
    /// a wedged sensor would otherwise freeze the menubar and the settings panel
    /// rather than merely failing to recover.
    ///
    /// Serial because `AccelSource` keeps `client`, `service`, `running` and
    /// `onSample` unguarded: a stop overlapping a start would double-release the
    /// client. A serial queue also keeps the reacquire's stop-then-start in that
    /// order without the main thread waiting for either.
    private let sensorQueue = DispatchQueue(label: "dev.tunk.engine.sensor", qos: .utility)

    /// Bumped on the main thread for every arm or disarm. A sensor call that
    /// comes back after a newer request has been made has its result dropped
    /// rather than publishing a status for a session that no longer exists —
    /// which is what a user toggling Enable detection mid-reacquire produces.
    private var sensorGeneration: UInt64 = 0

    /// A sensor call is on `sensorQueue` and has not come back. It may never
    /// come back; the watchdog uses this to avoid stacking up more of them.
    private var sensorBusy = false
    /// Watchdog ticks spent waiting for one. Turns a wedge into something the
    /// menubar can say rather than a status that quietly stays stale.
    private var sensorBusyTicks = 0
    /// Counts lifecycle work that reached a thread other than main. Every
    /// function that writes a `@Published` property or touches AppKit calls
    /// `requireMain()` first, so this is a measurement of the hazard rather than
    /// an argument about it. `tunk --reacquire-probe` prints it.
    nonisolated(unsafe) private(set) static var offMainViolations = 0
    private static let violationLock = NSLock()
    private var reacquireBackoff = 1
    private var wantsRunning = false
    private var catalogTicks = 0

    init(settings: AppSettings) {
        self.settings = settings
        let made = DetectorFactory.make(config: settings.effectiveConfig,
                                        armedTapCounts: settings.config.armedTapCounts,
                                        tuning: settings.tuning)
        self.detector = made
        self.readout = made as? TapDetector
        self.runner = ActionRunner(bindings: settings.bindings)

        settings.onConfigChange = { [weak self] config in self?.apply(config: config) }
        settings.onTuningChange = { [weak self] tuning in self?.apply(tuning: tuning) }
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
        // The source outlives this object by as long as the close takes. Going
        // through the same queue is what keeps it from overlapping a call that
        // is still in flight there — `AccelSource` would double-release its
        // client — and keeps the close off whichever thread dropped the last
        // reference.
        let source = accel
        sensorQueue.async { source.stop() }
        input?.stop()
    }

    // MARK: - lifecycle

    /// Records, rather than assumes, that a main-thread-only path is on the main
    /// thread. Deliberately not a `precondition`: a menubar utility that traps in
    /// a user's face is worse than the bug it is trapping on, and the count plus
    /// the log line is what a probe or a bug report actually needs.
    @inline(__always)
    private func requireMain(_ what: StaticString = #function) {
        guard !Thread.isMainThread else { return }
        Engine.violationLock.lock()
        Engine.offMainViolations += 1
        Engine.violationLock.unlock()
        NSLog("tunk: %@ ran off the main thread", String(describing: what))
    }

    func setEnabled(_ on: Bool) {
        requireMain()
        wantsRunning = on
        on ? start() : stop()
    }

    func refreshPermissions() {
        requireMain()
        let now = PermissionState.current()
        if now != permissions { permissions = now }
        if wantsRunning, case .needsPermission = status, now.ready { start() }
    }

    private func start() {
        requireMain()
        guard wantsRunning else { return }
        let perms = PermissionState.current()
        permissions = perms
        // Refuse to arm half-blind. A detector that cannot see keystrokes cannot
        // suppress typing, and typing false positives are the metric that
        // decides whether this app is worth running at all.
        guard perms.ready else {
            stopSensors()
            status = .needsPermission
            // Say so on stderr as well as in the menubar. Running the binary
            // from a terminal — which is how every probe and every collection
            // run starts — otherwise looks like a working app that simply never
            // sees a tap. Rebuilding the bundle revokes these grants, so this
            // fires far more often during development than in normal use.
            FileHandle.standardError.write(Data("""
            tunk: NOT ARMED — missing permission
              input monitoring: \(perms.inputMonitoring ? "granted" : "MISSING")
              accessibility:    \(perms.accessibility ? "granted" : "MISSING")
            Add this exact binary in System Settings > Privacy & Security, then
            relaunch. A rebuilt bundle is a new binary even at the same path, so
            the grant has to be renewed after every build.

            """.utf8))
            return
        }

        detectorLock.lock()
        // Do not overwrite the calibration probe. `apply(config:)` already
        // refuses this while a calibration is live; `start()` did not, and
        // start() is reachable mid-calibration from the watchdog's sensorLost
        // backoff, from didWake, and from the `.needsPermission -> ready`
        // branch — which is the FIRST-RUN path, where the user opens
        // "Calibrate…" and grants permission with the sheet already up.
        //
        // Measured over ten identical synthetic double-taps: the probe config
        // (0.020 g) fills 10 of 10 dots and learns a 207 ms window; the shipped
        // default (0.032 g) fills 6 and learns none; a prior desk calibration
        // (0.06 g) fills zero. The panel's only guard is "the sensor is not
        // running", and after start() it is running — so the dots simply stop
        // filling while the user keeps tapping.
        let live = configBeforeCalibration == nil ? settings.effectiveConfig : detector.config
        detector.config = live
        arm(for: live)
        detector.reset()
        detectorLock.unlock()

        // Created here rather than in init: the sensor epoch is not settled
        // until start(), and a collector holding a ring from a previous epoch
        // would write snippets whose timestamps mean nothing.
        //
        // Under the lock, because `feed(sample:)` reads it on the sensor thread
        // and a reacquire reaches this line while the old stream is still
        // delivering — `stopSensors()` only queues the close. Thread Sanitizer
        // caught this one: `feed(sample:)` reading it on a GCD worker against
        // this write on main.
        let collector = PassiveCollection.makeIfRequested()
        detectorLock.lock()
        if passive == nil { passive = collector }
        detectorLock.unlock()

        // The keystroke gate is a pair of `NSEvent` monitors, which are AppKit
        // objects: they are installed and removed here, on the main thread, and
        // nowhere else. Assigning over `input` stops the old monitor through its
        // deinit, which matters because start() is reachable on an already-armed
        // engine from didWake and from the watchdog.
        let monitor = InputActivityMonitor(epochNs: { [weak self] in self?.epochNs ?? 0 }) {
            [weak self] event in self?.feed(input: event)
        }
        monitor.start()
        input = monitor

        // Opening the sensor is the part that can hang, so it is the only part
        // that leaves this thread. Nothing it touches is `@Published` and
        // nothing it touches is AppKit; the result comes back to main to be
        // published. See `sensorQueue`.
        let onSample: (AccelSample) -> Void = { [weak self] sample in self?.feed(sample: sample) }
        let generation = beginSensorOp()
        let source = accel
        let epoch = epochNs
        let box = WeakEngineRef(self)
        sensorQueue.async {
            var failure: String?
            do { try source.start(epochMachNs: epoch, onSample: onSample) }
            catch { failure = String(describing: error) }
            let count = source.snapshotStats().sampleCount
            DispatchQueue.main.async {
                box.engine?.finishSensorStart(generation, failure: failure, sampleCount: count)
            }
        }
    }

    /// Publishes what the sensor open did. Main thread, like every other write
    /// of `status` in this file.
    private func finishSensorStart(_ generation: UInt64, failure: String?, sampleCount: UInt64) {
        requireMain()
        // A newer arm or disarm has already been asked for — most likely the
        // user toggling Enable detection while this was in flight. Publishing
        // now would announce a session that has been superseded.
        guard generation == sensorGeneration else { return }
        endSensorOp()
        guard wantsRunning else { return }
        if let failure {
            status = .sensorLost(failure)
            return
        }
        lastSampleCount = sampleCount
        starvedTicks = 0
        reacquireBackoff = 1
        status = .running
    }

    private func stop() {
        requireMain()
        stopSensors()
        status = .off
        sampleRateHz = 0
    }

    /// Closes the keystroke gate here and the sensor on `sensorQueue`.
    ///
    /// Returns as soon as the close is queued. That is the point: closing the
    /// sensor is half of the stop/start pair measured to hang, and the caller is
    /// usually the main-thread watchdog. A later start queues behind this one,
    /// so the pair still happens in order.
    private func stopSensors() {
        requireMain()
        input?.stop()
        input = nil
        let generation = beginSensorOp()
        let source = accel
        let box = WeakEngineRef(self)
        sensorQueue.async {
            source.stop()
            DispatchQueue.main.async {
                guard let engine = box.engine, engine.sensorGeneration == generation else { return }
                engine.endSensorOp()
            }
        }
    }

    /// Marks a sensor call as in flight and returns its generation. Main only.
    private func beginSensorOp() -> UInt64 {
        requireMain()
        sensorGeneration &+= 1
        sensorBusy = true
        sensorBusyTicks = 0
        return sensorGeneration
    }

    private func endSensorOp() {
        requireMain()
        sensorBusy = false
        sensorBusyTicks = 0
    }

    // MARK: - hot path

    private func feed(sample: AccelSample) {
        // The user asking for off has to mean off IMMEDIATELY, not once a queued
        // close finishes. `stopSensors()` returns as soon as the close is
        // enqueued, so on a wedged sensor queue the stream keeps arriving after
        // the switch is flipped — measured at 4069 samples during a 5 s wedge,
        // against 1 with a healthy queue. Worse, the keystroke gate's monitors
        // are removed first, so those samples would reach a detector with the
        // typing defence already gone, and a trigger from one of them would run
        // the bound action. `wantsRunning` is written on main before any of that
        // starts, so reading it here closes the window with one branch.
        guard wantsRunning else { return }
        detectorLock.lock()
        let trigger = detector.ingest(sample: sample)
        let onsets = detector.drainOnsets()
        // The detector's own transient envelope, in g. Drawing that rather than
        // a second filter of our own keeps the trace, the onset spikes and the
        // threshold line in one coordinate system.
        recordEnvelope(tNs: sample.tNs, value: Float(readout?.envelope ?? 0))
        // Onsets first: a new onset closes the previous ring measurement, and
        // this sample then belongs to the new one.
        for onset in onsets { record(onset: onset) }
        if configBeforeCalibration != nil {
            accumulateRing(nowNs: sample.tNs, envelope: readout?.envelope ?? 0)
        }
        // Passive capture, off unless deliberately switched on. Fed the same
        // onsets the monitor draws, so it keeps the seconds around anything
        // tap-shaped without a second detector or a second filter.
        if let passive {
            passive.ingest(sample: sample)
            for onset in onsets {
                passive.noteCandidate(atNs: onset.tNs, strength: onset.strength,
                                      suppressed: onset.suppressedByGate)
            }
        }
        // The live acceptance recorder, off unless `--record` asked for it. Fed
        // the raw stream, so the file it writes is what the sensor delivered
        // rather than what the detector made of it.
        recorder?.ingest(sample: sample)
        if let trigger {
            record(trigger: trigger)
            onTriggerForTesting?(trigger)
            // A mark, never a label. See `AcceptanceRecorder`.
            recorder?.noteLiveTrigger(atNs: trigger.tNs,
                                      lastOnsetNs: trigger.tapOnsets.last ?? trigger.tNs,
                                      tapCount: trigger.tapCount)
        }
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
        // The failure is kept, not swallowed. It used to be `_ = try?`, and
        // then `triggerCount` incremented and the glyph flashed regardless — so
        // a hotkey being eaten by secure input, or a Shortcut that no longer
        // exists, looked exactly like a working tap from the menubar. The text
        // was visible only to somebody who already had Settings open, which is
        // nobody who does not already suspect a problem.
        var actionFailed = false
        do { _ = try runner.run(for: trigger) } catch { actionFailed = true }

        // Measured after the runner returns, so this is onset-to-handoff: the
        // keystroke is out, or the shortcut has been handed to its own queue.
        // What a shortcut then does with its own time is `ActionStats`'s
        // completion latency and is not part of this number.
        let latencyMs = Double(nowNs() - (trigger.tapOnsets.last ?? trigger.tNs)) / 1_000_000

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.triggerCount += 1
            self.lastLatencyMs = latencyMs
            // Counted as detected either way — the gesture DID happen, and
            // pretending otherwise would hide a detector working correctly
            // behind an action that is not. The failure rides alongside.
            self.lastActionFailed = actionFailed
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
        // Input goes into the snippet too. Without it the harness cannot
        // reproduce the suppression gate when replaying one, and a snippet that
        // cannot be replayed faithfully is worth very little.
        let asRecord = InputRecord(tNs: e.tNs, kind: e.kind,
                                   code: e.code >= 0 ? e.code : nil)
        passive?.ingest(input: asRecord)
        // Same reason, and it is what makes a typing recording replayable at
        // all: the gate is the only thing that stops typing firing Tunk.
        recorder?.ingest(input: asRecord)
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
            calibrationOnsetTimes.append(onset.tNs)
            // Close out any previous measurement before starting this one, so a
            // fast second tap cannot silently overwrite the first's window.
            flushRingMeasurement()
            ringPending = (tNs: onset.tNs, peak: onset.strength, ring: 0)
        }
    }

    /// Accumulates the ring measurement for the onset currently being watched.
    /// Called per sample while calibrating; costs one comparison otherwise.
    private func accumulateRing(nowNs: Int64, envelope: Double) {
        guard var p = ringPending else { return }
        let age = nowNs - p.tNs
        if age >= 60_000_000 && age <= 100_000_000 {
            p.ring = max(p.ring, envelope)
            ringPending = p
        } else if age > 100_000_000 {
            flushRingMeasurement()
        }
    }

    private func flushRingMeasurement() {
        if let p = ringPending, p.peak > 0, p.ring > 0 {
            calibrationRingRatios.append(p.ring / p.peak)
        }
        ringPending = nil
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
        // The value posted here is the DERIVED one (`effectiveConfig`), which
        // must not become the restore base: `endCalibration` reads the stored
        // `settings.config`, which AppSettings keeps current through any write.
        if configBeforeCalibration == nil {
            detector.config = config
            arm(for: config)
        }
        detectorLock.unlock()
    }

    /// Swap in a detector built on a different `DSPTuning`.
    ///
    /// A detector reads its tuning once, in `init`, and `TapDetector.tuning` is a
    /// `let` — the crest buffer and the polarization tracker are allocated there
    /// or not at all. So this rebuilds rather than writes, which also means the
    /// new detector starts with no history: any half-formed group the old one was
    /// holding dies here rather than being counted under new rules. That is the
    /// same discipline `reset()` follows on a sensor reacquire.
    ///
    /// The config carried across is whatever is in force, which during
    /// calibration is the probe rather than the user's — the calibration sheet
    /// still owns `configBeforeCalibration` and still restores it on commit.
    private func apply(tuning: DSPTuning) {
        detectorLock.lock()
        let live = detector.config
        let armed = detector.effectiveArmedTapCounts
        let made = DetectorFactory.make(config: live, armedTapCounts: armed, tuning: tuning)
        detector = made
        readout = made as? TapDetector
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
        calibrationOnsetTimes.removeAll(keepingCapacity: true)
        calibrationRingRatios.removeAll(keepingCapacity: true)
        ringPending = nil
        calibrationSuppressed = 0
        detectorLock.unlock()
        isCalibrating = true
    }

    /// Strengths gathered so far, plus how many onsets the gate threw away —
    /// the user needs to know when their resting hand is eating their taps —
    /// plus the noise floor the calibration has to clear, plus the time each
    /// onset landed so the gesture's rhythm can be fitted as well as its force.
    func calibrationProgress() -> (strengths: [Double], onsetTimesNs: [Int64],
                                   suppressed: Int, noiseFloor: Double,
                                   ringRatios: [Double]) {
        detectorLock.lock(); defer { detectorLock.unlock() }
        return (calibrationStrengths, calibrationOnsetTimes,
                calibrationSuppressed, readout?.noiseFloor ?? 0, calibrationRingRatios)
    }

    /// The sensitivity slider's value, which is held out of the way while taps
    /// are measured (`beginCalibration` probes at 1.0) and then multiplies
    /// whatever threshold this step derives, because `effectiveThreshold` is
    /// `calibratedThreshold * sensitivity`.
    ///
    /// The review screen needs it or it reports a bar the detector will not run:
    /// at sensitivity 1.35 a derived 0.42 g goes into force as 0.567 g, and a
    /// "your weakest tap clears by 1.25x" verdict computed against 0.42 is then
    /// wrong about the only thing it is there to say.
    var calibrationSensitivity: Double {
        detectorLock.lock(); defer { detectorLock.unlock() }
        return (configBeforeCalibration ?? settings.config).sensitivity
    }

    /// Runs one row's action once, on demand, for that row's Test button.
    ///
    /// This and a real tap are the only two things in Tunk that may run a user's
    /// Shortcut. Nothing probes, validates, warms up or benchmarks one — the
    /// stale-name check reads `shortcuts list` and never runs anything.
    @discardableResult
    func testAction(tapCount: Int) throws -> ActionStats {
        // Waits, unlike a real tap: the user pressed a button and is owed an
        // answer. The sensor thread is not involved here.
        let stats = try runner.run(settings.bindings[tapCount], tapCount: tapCount,
                                   waitForHotkey: true)
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

    /// Clears everything `beginCalibration` clears. It used to clear three of
    /// five, so "Start over" kept the abandoned attempt's ring ratios and they
    /// kept voting in the median.
    ///
    /// Modelled on the panel's own scenario — a first attempt with a forearm on
    /// the case, abandoned, then a clean attempt with the arm lifted:
    ///
    ///     no restart          35 %  "settles quickly ... most reliable"
    ///     after 1 Start over  39 %  "settles quickly"
    ///     after 2 Start over  60 %  "rings loudly ... expect some misses"
    ///     after 3 Start over  61 %  "rings loudly"
    ///
    /// Two restarts flipped the verdict, and the advice the user then got
    /// described taps they had thrown away. My own bug, from the commit that
    /// added the ring measurement.
    func clearCalibrationSamples() {
        detectorLock.lock()
        calibrationStrengths.removeAll(keepingCapacity: true)
        calibrationOnsetTimes.removeAll(keepingCapacity: true)
        calibrationRingRatios.removeAll(keepingCapacity: true)
        ringPending = nil
        calibrationSuppressed = 0
        detectorLock.unlock()
    }

    /// Ends the learn step. `commit` writes the derived calibration into the one
    /// `DetectorConfig` everything reads.
    ///
    /// Commits a whole calibration, not just its threshold: the learned join
    /// window has to travel with it. `TapCalibration.apply` is the single place
    /// that decides which fields a calibration owns, so the window and the
    /// confirm window move together and the coherence clamp does not undo one
    /// of them on the way out.
    @discardableResult
    func endCalibration(commit result: CalibrationResult?) -> Bool {
        detectorLock.lock()
        guard configBeforeCalibration != nil else { detectorLock.unlock(); return false }
        configBeforeCalibration = nil
        let before = settings.config
        let restored = result.map { TapCalibration.apply($0, to: before) } ?? before
        detector.config = restored
        arm(for: restored)
        detector.reset()
        detectorLock.unlock()

        isCalibrating = false
        settings.config = restored          // persists, and hands the same struct back
        return result != nil
    }

    /// Blocks until any in-flight key pair has finished posting. See
    /// `HotkeyEmitter.drainPending`.
    func drainPendingEmissions() { runner.drainPending() }

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

    /// Tear the sensor down and open it again. Factored out of the watchdog so
    /// `tunk --reacquire-probe` drives exactly the code the watchdog drives,
    /// rather than a copy of it that could drift.
    ///
    /// Both halves return as soon as the IOHID work is queued, so this costs the
    /// watchdog tick that calls it a few microseconds rather than however long a
    /// wedged sensor feels like taking. The stop and the start land on the same
    /// serial queue in that order.
    private func reacquire() {
        requireMain()
        stopSensors()
        start()
    }

    private func watchdog() {
        requireMain()
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

        // A sensor call that has not come back. It is on its own queue and the
        // UI is alive, which is the whole point — but a menubar reading
        // "Detection off" while the app is in fact trying and failing to arm is
        // a lie, so after three ticks say what is happening. The `.sensorLost`
        // branch below then waits rather than stacking a second call behind a
        // stuck one.
        if sensorBusy {
            sensorBusyTicks += 1
            if sensorBusyTicks >= 3, case .off = status {
                status = .sensorLost("accelerometer has not answered in \(sensorBusyTicks) s")
            }
        }

        // A stream that is running but far off its nominal rate is worse than a
        // dead one, because everything downstream keeps reporting success. The
        // filter coefficients are computed once from DSPTuning.sampleRateHz, so
        // a half-rate stream runs through a chain designed for a rate it does
        // not have: measured on a decimated corpus, pooled detection falls
        // 82.11 % to 72.36 % and soft 100 % to 50 %, with latency unchanged.
        let nominal = DSPTuning.default.sampleRateHz
        let rateIsWrong = delta > 0 && (sampleRateHz < nominal * 0.75
                                        || sampleRateHz > nominal * 1.25)

        switch status {
        case .running where delta == 0 || rateIsWrong:
            starvedTicks += 1
            if starvedTicks >= 2 {
                status = delta == 0
                    ? .sensorLost("no samples for \(starvedTicks) s")
                    : .sensorLost(String(format: "%.0f Hz, expected %.0f", sampleRateHz, nominal))
                // Deliberately NOT resetting reacquireBackoff here. It used to
                // reset on every entry, and a reacquire that opens the service
                // but gets no data always passes through .running first — so the
                // backoff never grew. Measured against a real source held idle:
                // 13 reacquires in 40 s, backoff pinned at 1, status flapping
                // every 3 s, against a comment promising "1, 2, 4 … 32 s. Never
                // a spin." It was a fixed 3.08 s spin, forever.
            }
        case .running:
            starvedTicks = 0
            // Reset the backoff only once the stream has actually been healthy
            // for a while, not merely because we reached .running.
            healthyTicks += 1
            if healthyTicks >= 5 { reacquireBackoff = 1 }
        case .sensorLost where sensorBusy:
            break        // one is already queued, and it may never come back
        case .sensorLost:
            // Bounded backoff: 1, 2, 4 … 32 s. Never a spin.
            healthyTicks = 0
            starvedTicks += 1
            if starvedTicks >= reacquireBackoff {
                starvedTicks = 0
                reacquireBackoff = min(reacquireBackoff * 2, 32)
                // Cheap from here: `reacquire()` queues the IOHID work on
                // `sensorQueue` and returns. It still may not recover the
                // sensor; it will not take this Timer, the menubar or the
                // settings panel with it, and it publishes nothing from that
                // queue.
                reacquire()
            }
        case .needsPermission:
            // Not while a sensor call is outstanding: a start would only queue
            // behind it, and this branch fires every second.
            if !sensorBusy, PermissionState.current().ready { start() }
        case .off:
            break
        }
    }
}

// MARK: - probe seam

/// Drives the watchdog's two halves separately so `tunk --reacquire-probe` can
/// run them against each other. Nothing in the shipped paths calls these; they
/// exist so a reviewer can measure the threading rather than read an argument
/// about it, and they call the real methods so the probe cannot drift from what
/// ships.
extension Engine {
    func probeReacquire() { reacquire() }
    func probeWatchdogTick() { watchdog() }
    var probeIsBusy: Bool { sensorBusy }
    /// A plain stored property that `start()` writes and `watchdog()` writes,
    /// exposed because Thread Sanitizer cannot see through `@Published` — the
    /// load and the store both happen inside Combine, which is not instrumented.
    /// The threads and the synchronisation are identical, so a report on this
    /// one is a report on `status` and `permissions` too.
    var probeSampleCount: UInt64 { lastSampleCount }
    /// Blocks `sensorQueue` for `seconds`, which is what a wedged
    /// `IOHIDEventSystemClientScheduleWithDispatchQueue` does to it. Every stop
    /// and start the app then asks for queues behind this. The probe holds it
    /// there and watches whether the main thread notices.
    func probeWedgeSensorQueue(seconds: Double) {
        sensorQueue.async { Thread.sleep(forTimeInterval: seconds) }
    }
}

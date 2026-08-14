import CTunkHID
import CoreFoundation
import Foundation
import TunkCore

/// Converts `mach_absolute_time()` ticks to nanoseconds. Cached once.
public enum MachClock {
    nonisolated(unsafe) private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    @inline(__always)
    public static func toNanos(_ ticks: UInt64) -> Int64 {
        Int64(ticks &* UInt64(timebase.numer) / UInt64(timebase.denom))
    }

    @inline(__always)
    public static func nowNanos() -> Int64 { toNanos(mach_absolute_time()) }
}

public enum AccelSourceError: Error, CustomStringConvertible {
    case clientCreateFailed
    case noMatchingService
    case activationRejected

    public var description: String {
        switch self {
        case .clientCreateFailed:
            return "IOHIDEventSystemClientCreate returned null"
        case .noMatchingService:
            return "no accelerometer service matched usage page 0xFF00 / usage 3 — "
                 + "either this Mac has no SPU accelerometer or Input Monitoring is not granted"
        case .activationRejected:
            return "the accelerometer service refused ReportInterval; it will stay idle"
        }
    }
}

/// Reads the built-in accelerometer at a requested rate and hands samples to a
/// callback on a dedicated serial queue.
///
/// The sensor is idle until `ReportInterval` is set — that was measured, not
/// assumed. With `reportIntervalUs = 1250` this machine delivers 796 Hz with a
/// p95 event-to-callback lag of 0.34 ms and no batching.
public final class AccelSource {
    /// The interval actually being delivered, learned from the stream. See the
    /// gap test in `handle(event:)`.
    private var deliveredIntervalNs: Int64 = 1_250_000

    public struct Stats: Sendable {
        public var sampleCount: UInt64 = 0
        public var gapCount: UInt64 = 0
        public var lastSampleNs: Int64 = 0
        public var maxLagNs: Int64 = 0
    }

    /// Nanoseconds since this source's epoch, matching FORMAT.md.
    public private(set) var epochMachNs: Int64 = 0
    public let reportIntervalUs: Int64
    public var nominalIntervalNs: Int64 { reportIntervalUs * 1_000 }

    private var client: TunkHIDEventSystemClientRef?
    private var service: TunkHIDServiceClientRef?

    /// Ask the service for one property by name. Read-only.
    ///
    /// Exists because the recorded stream is band-limited near 50 Hz while
    /// reporting at 796 Hz — measured, see notes/BAR_ASSESSMENT.md — and whether
    /// that ceiling is a configurable filter or a fixed property of the part
    /// decides whether tap-versus-ring discrimination is reachable at all.
    public func property(_ key: String) -> String? {
        guard let svc = service,
              let v = IOHIDServiceClientCopyProperty(svc, key as CFString) else { return nil }
        return CFCopyDescription(v) as String
    }
    private let queue = DispatchQueue(label: "dev.tunk.accel", qos: .userInteractive)
    private var onSample: ((AccelSample) -> Void)?
    private var stats = Stats()
    private let statsLock = NSLock()
    private var running = false

    public init(reportIntervalUs: Int64 = 1250) {
        self.reportIntervalUs = reportIntervalUs
    }

    public func snapshotStats() -> Stats {
        statsLock.lock(); defer { statsLock.unlock() }
        return stats
    }

    /// Open the sensor and begin delivering samples. `epochMachNs` is set to now
    /// unless one is supplied, so a capture session can share an epoch with its
    /// input-event log.
    public func start(epochMachNs: Int64? = nil,
                      onSample: @escaping (AccelSample) -> Void) throws {
        guard !running else { return }
        self.epochMachNs = epochMachNs ?? MachClock.nowNanos()
        self.onSample = onSample

        guard let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            throw AccelSourceError.clientCreateFailed
        }
        client = c

        var page = kTunkAccelUsagePage
        var usage = kTunkAccelUsage
        let pageRef = CFNumberCreate(nil, .sInt32Type, &page)!
        let usageRef = CFNumberCreate(nil, .sInt32Type, &usage)!
        let match = [
            "PrimaryUsagePage": pageRef,
            "PrimaryUsage": usageRef,
        ] as CFDictionary
        IOHIDEventSystemClientSetMatching(c, match)

        guard let services = IOHIDEventSystemClientCopyServices(c),
              CFArrayGetCount(services) > 0 else {
            throw AccelSourceError.noMatchingService
        }
        let svc = unsafeBitCast(CFArrayGetValueAtIndex(services, 0), to: TunkHIDServiceClientRef.self)
        service = svc

        var interval = reportIntervalUs
        let intervalRef = CFNumberCreate(nil, .sInt64Type, &interval)!
        guard IOHIDServiceClientSetProperty(svc, "ReportInterval" as CFString, intervalRef) else {
            throw AccelSourceError.activationRejected
        }
        // Ask for immediate delivery rather than batched. Best effort: the
        // measured stream is already unbatched without it.
        var zero: Int64 = 0
        let zeroRef = CFNumberCreate(nil, .sInt64Type, &zero)!
        _ = IOHIDServiceClientSetProperty(svc, "BatchInterval" as CFString, zeroRef)

        let target = Unmanaged.passUnretained(self).toOpaque()
        IOHIDEventSystemClientRegisterEventCallback(c, accelEventTrampoline, target, nil)
        IOHIDEventSystemClientScheduleWithDispatchQueue(c, queue)
        running = true
    }

    public func stop() {
        guard running, let c = client else { return }
        let target = Unmanaged.passUnretained(self).toOpaque()
        IOHIDEventSystemClientUnscheduleFromDispatchQueue(c, queue)
        IOHIDEventSystemClientUnregisterEventCallback(c, accelEventTrampoline, target, nil)
        // Let the sensor idle again so an unloaded Tunk costs nothing.
        if let svc = service {
            var idle: Int64 = 0
            if let idleRef = CFNumberCreate(nil, .sInt64Type, &idle) {
                _ = IOHIDServiceClientSetProperty(svc, "ReportInterval" as CFString, idleRef)
            }
        }
        queue.sync {}
        // Release the client explicitly. `TunkHIDEventSystemClientRef` is an
        // opaque `struct __IOHIDEventSystemClient *`, so Swift sees a raw
        // pointer and ARC does nothing on `client = nil` — but the object is a
        // CF type created with `...Create`, and that is an owning reference.
        //
        // Measured before this line existed: 100 start/stop cycles took the
        // process from 22 mach ports to 525, exactly 5 per cycle, monotone,
        // never reclaimed, with RSS 6.2 -> 10.4 MB. The watchdog reacquires on
        // a wedged sensor, so a stuck stream leaked about 5,800 ports an hour.
        if let c = client {
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(c)).release()
        }
        client = nil
        service = nil
        running = false
    }

    /// Tear down and re-open. Used after wake, when the SPU device may have gone
    /// away and come back under a new service.
    public func reacquire() throws {
        let cb = onSample
        let epoch = epochMachNs
        stop()
        guard let cb else { return }
        try start(epochMachNs: epoch, onSample: cb)
    }

    fileprivate func handle(event: TunkHIDEventRef) {
        guard IOHIDEventGetType(event) == kTunkEventTypeAccelerometer else { return }
        let arrival = MachClock.nowNanos() - epochMachNs
        let deviceNs = MachClock.toNanos(IOHIDEventGetTimeStamp(event)) - epochMachNs
        let sample = AccelSample(
            tNs: deviceNs,
            arrivalNs: arrival,
            x: Float(IOHIDEventGetFloatValue(event, TunkAccelField(0))),
            y: Float(IOHIDEventGetFloatValue(event, TunkAccelField(1))),
            z: Float(IOHIDEventGetFloatValue(event, TunkAccelField(2)))
        )

        statsLock.lock()
        // Measured against the DELIVERED cadence, not the requested one.
        //
        // `nominalIntervalNs` is derived from `reportIntervalUs`, which is what
        // was asked for. The SPU caps at 796 Hz, so asking for 625 us gets
        // 1250 us delivered — a perfectly regular stream in which EVERY
        // interval exceeds 1.5x the requested one. Measured at 625 us: 3183
        // samples, 796.34 Hz, interval p50 1250 us, max 1298 us, zero
        // non-monotonic stamps, zero duplicates — and gapCount 3182. A capture
        // at that setting reported a broken stream that was not broken.
        //
        // The delivered interval is learned from the stream itself, so the gap
        // test asks the question it means: did this sample arrive far later than
        // the ones before it.
        if stats.sampleCount > 8 {
            let step = sample.tNs - stats.lastSampleNs
            if step > deliveredIntervalNs * 3 / 2 { stats.gapCount += 1 }
            // Slow EMA, so a real gap barely moves the reference it is measured
            // against but a genuine rate change is tracked within a second.
            deliveredIntervalNs += (min(step, deliveredIntervalNs * 4) - deliveredIntervalNs) / 64
        } else if stats.sampleCount > 0 {
            deliveredIntervalNs = max(1, sample.tNs - stats.lastSampleNs)
        }
        stats.sampleCount += 1
        stats.lastSampleNs = sample.tNs
        stats.maxLagNs = max(stats.maxLagNs, arrival - deviceNs)
        statsLock.unlock()

        onSample?(sample)
    }
}

/// C callback trampoline. Kept at file scope so its address is stable across
/// register / unregister.
private let accelEventTrampoline: TunkHIDEventCallback = { target, _, _, event in
    guard let target, let event else { return }
    let source = Unmanaged<AccelSource>.fromOpaque(target).takeUnretainedValue()
    source.handle(event: event)
}

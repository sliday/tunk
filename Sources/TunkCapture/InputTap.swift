import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import TunkCore
import TunkFormat
import TunkIMU

/// Live keyboard / trackpad activity capture via a listen-only CGEventTap.
///
/// This is not optional garnish: the offline harness replays `input.jsonl` to
/// reproduce the suppression gate. A session without it cannot be scored for
/// false positives, so a failed tap is a hard error unless the operator opts out.
///
/// Callbacks fire on the **main** run loop, which must be running
/// (`CFRunLoopRun()`), regardless of which thread called `start()`.
final class InputTap {
    enum StartError: Error, CustomStringConvertible {
        case notPermitted
        case runLoopSourceFailed

        var description: String {
            switch self {
            case .notPermitted:
                return "CGEvent.tapCreate was refused — Input Monitoring / Accessibility not granted"
            case .runLoopSourceFailed:
                return "could not build a run loop source for the event tap"
            }
        }
    }

    /// Nanoseconds since the session epoch.
    private let clock: () -> Int64
    private let sink: (InputRecord) -> Void
    private let captureTouches: Bool

    private var machPort: CFMachPort?
    private var source: CFRunLoopSource?
    private var stopped = false

    private var lastMoveNs: Int64?
    private var lastTouchNs: Int64?
    private var lastTouchCount = -1
    private let moveMinIntervalNs: Int64 = 10_000_000  // 100 Hz cap, per FORMAT.md

    private(set) var eventCount = 0
    private(set) var reEnableCount = 0

    /// NSEventTypeGesture. CGEventType has no constant for it, so the mask bit is
    /// set numerically. Only this one type carries the touching set; the magnify /
    /// swipe / begin-end gesture types repeat the same contact with a zero count
    /// and doubled the row rate when they were included.
    private static let gestureBits: [UInt32] = [29]

    init(clock: @escaping () -> Int64,
         captureTouches: Bool,
         sink: @escaping (InputRecord) -> Void) {
        self.clock = clock
        self.captureTouches = captureTouches
        self.sink = sink
    }

    static func eventMask(captureTouches: Bool) -> CGEventMask {
        var mask: CGEventMask = 0
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .scrollWheel,
        ]
        for t in types { mask |= (1 << CGEventMask(t.rawValue)) }
        if captureTouches {
            for b in gestureBits { mask |= (1 << CGEventMask(b)) }
        }
        return mask
    }

    func start() throws {
        let mask = InputTap.eventMask(captureTouches: captureTouches)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .tailAppendEventTap,
                                           options: .listenOnly,
                                           eventsOfInterest: mask,
                                           callback: inputTapTrampoline,
                                           userInfo: refcon) else {
            throw StartError.notPermitted
        }
        guard let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            throw StartError.runLoopSourceFailed
        }
        machPort = port
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    func stop() {
        guard let port = machPort else { return }
        stopped = true
        CGEvent.tapEnable(tap: port, enable: false)
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        CFMachPortInvalidate(port)
        source = nil
        machPort = nil
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = machPort, !stopped {
                CGEvent.tapEnable(tap: port, enable: true)
                reEnableCount += 1
            }
            return
        }
        guard !stopped else { return }
        let t = clock()

        switch type.rawValue {
        case CGEventType.keyDown.rawValue:
            emit(InputRecord(tNs: t, kind: .keyDown, code: keycode(event)))
        case CGEventType.keyUp.rawValue:
            emit(InputRecord(tNs: t, kind: .keyUp, code: keycode(event)))
        case CGEventType.flagsChanged.rawValue:
            // Key code only. FORMAT.md's example carries a `flags` field, but
            // InputRecord has no such column; the gate only needs the kind.
            emit(InputRecord(tNs: t, kind: .flagsChanged, code: keycode(event)))
        case CGEventType.leftMouseDown.rawValue, CGEventType.rightMouseDown.rawValue,
             CGEventType.otherMouseDown.rawValue:
            emit(InputRecord(tNs: t, kind: .mouseDown, code: button(event)))
        case CGEventType.leftMouseUp.rawValue, CGEventType.rightMouseUp.rawValue,
             CGEventType.otherMouseUp.rawValue:
            emit(InputRecord(tNs: t, kind: .mouseUp, code: button(event)))
        case CGEventType.mouseMoved.rawValue, CGEventType.leftMouseDragged.rawValue,
             CGEventType.rightMouseDragged.rawValue:
            if let last = lastMoveNs, t - last < moveMinIntervalNs { return }
            lastMoveNs = t
            emit(InputRecord(tNs: t, kind: .mouseMoved))
        case CGEventType.scrollWheel.rawValue:
            emit(InputRecord(tNs: t, kind: .scroll))
        default:
            guard captureTouches, InputTap.gestureBits.contains(type.rawValue) else { return }
            handleTouches(t: t, event: event)
        }
    }

    /// Trackpad contact count, read back through NSEvent. Gesture events carry the
    /// touch set; a resting finger repeats at ~120 Hz, so this only writes a row
    /// when the count changes or the 100 Hz budget allows it.
    private func handleTouches(t: Int64, event: CGEvent) {
        guard let ns = NSEvent(cgEvent: event) else { return }
        let count = ns.touches(matching: .touching, in: nil).count
        // A change in contact count is what arms the gate, so it is written
        // promptly; an unchanged count is a heartbeat capped at 100 Hz.
        if let last = lastTouchNs {
            let elapsed = t - last
            if count == lastTouchCount, elapsed < moveMinIntervalNs { return }
            if count != lastTouchCount, elapsed < 2_000_000 { return }
        }
        lastTouchNs = t
        lastTouchCount = count
        emit(InputRecord(tNs: t, kind: .trackpadTouch, count: count))
    }

    private func emit(_ r: InputRecord) {
        eventCount += 1
        sink(r)
    }

    private func keycode(_ e: CGEvent) -> Int32 {
        Int32(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))
    }

    private func button(_ e: CGEvent) -> Int32 {
        Int32(truncatingIfNeeded: e.getIntegerValueField(.mouseEventButtonNumber))
    }
}

private let inputTapTrampoline: CGEventTapCallBack = { _, type, event, refcon in
    if let refcon {
        Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Permission reporting

enum InputPermission {
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// The process that actually owns the TCC grant. Launched from a terminal, the
    /// grant lives on the terminal app, not on this binary, and that trips people up.
    static var hostDescription: String {
        let name = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "your terminal app"
        return name
    }

    static func failureAdvice() -> String {
        """
        The input event tap could not start, so input.jsonl would be empty and the
        session unusable for false-positive scoring. Fix it, do not record around it.

        Grant BOTH of these to \(hostDescription) (the terminal you launched this from,
        not the tunk-capture binary):

          1. System Settings > Privacy & Security > Input Monitoring
             click +, add \(hostDescription), turn it ON
          2. System Settings > Privacy & Security > Accessibility
             click +, add \(hostDescription), turn it ON

        Then QUIT AND REOPEN \(hostDescription) — macOS only re-reads the grant on
        process launch — and run `tunk-capture doctor` to confirm.

        Accessibility currently reports: \(accessibilityTrusted ? "granted" : "NOT granted").

        If you truly want a session without input capture (it cannot be scored for
        false positives) re-run with --allow-no-input.
        """
    }
}

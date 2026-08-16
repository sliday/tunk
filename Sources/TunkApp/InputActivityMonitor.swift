import AppKit
import Foundation
import TunkCore

/// Watches keyboard and trackpad activity so the detector can suppress onsets
/// that a keystroke caused. This is the single mechanism that kills typing false
/// positives, so it fails loudly rather than silently delivering nothing.
///
/// SEAM: `Package.swift` puts the input-activity source in `TunkIMU` next to
/// `AccelSource`. That file does not exist yet, so this local monitor stands in.
/// It is deliberately thin — an `NSEvent` global monitor, one mapping table, one
/// callback — so moving it costs nothing.
///
/// Known gap, flagged rather than papered over: a global `NSEvent` monitor sees
/// clicks, gestures and force-touch pressure, but it cannot see a finger merely
/// resting on the trackpad. `InputEventKind.trackpadTouch` is therefore only
/// emitted for gesture and pressure events. Full resting-touch coverage needs a
/// `CGEventTap` in `TunkIMU`.
final class InputActivityMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let onEvent: (InputEvent) -> Void
    private let epochNs: () -> Int64

    private static let mask: NSEvent.EventTypeMask = [
        .keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp,
        .scrollWheel, .pressure,
        .magnify, .swipe, .rotate, .beginGesture, .endGesture,
    ]

    init(epochNs: @escaping () -> Int64, onEvent: @escaping (InputEvent) -> Void) {
        self.epochNs = epochNs
        self.onEvent = onEvent
    }

    var isRunning: Bool { globalMonitor != nil }

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] event in
            self?.handle(event)
        }
        // Our own settings window swallows the events it receives; without this
        // the gate would go blind exactly while the user is typing into Tunk.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        globalMonitor = nil
        localMonitor = nil
    }

    deinit { stop() }

    /// Set only by the live acceptance test; nil in normal operation, so this
    /// costs one nil check per event.
    ///
    /// Receives HID DELIVERY LAG in seconds: how long after the hardware stamped
    /// an event this process was handed it. That number decides whether the
    /// detector may fire before waiting out its confirm window. The retroactive
    /// keystroke gate reaches back `preGateNs` (25 ms) to kill an onset whose
    /// chassis shock beat the keystroke, and with the shipped deadline there is
    /// about 290 ms of slack for a late event to arrive in. Firing early would
    /// cut that slack to the settle constant, so `rejected/early-fire-on-count`
    /// records that it is "worth reviving only if HID delivery jitter is
    /// measured on this machine and earlySettleNs is set from it rather than
    /// from preGateNs". Nobody could measure it, because `input.jsonl` records
    /// only the hardware stamp and never the arrival.
    nonisolated(unsafe) static var deliveryLagSink: ((Double) -> Void)?

    private func handle(_ event: NSEvent) {
        guard let kind = Self.kind(for: event.type) else { return }
        // One clock everywhere (FORMAT.md). `NSEvent.timestamp` is seconds since
        // boot on the same mach timebase, so it converts without a wall clock.
        let tNs = Int64(event.timestamp * 1_000_000_000) - epochNs()
        if let sink = Self.deliveryLagSink {
            // Both sides are the same mach timebase, so this is a pure delivery
            // measurement with no wall clock and no drift.
            sink(max(0, ProcessInfo.processInfo.systemUptime - event.timestamp))
        }
        let code: Int32
        switch event.type {
        case .keyDown, .keyUp: code = Int32(event.keyCode)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp: code = Int32(event.buttonNumber)
        default: code = -1
        }
        onEvent(InputEvent(tNs: tNs, kind: kind, code: code))
    }

    private static func kind(for type: NSEvent.EventType) -> InputEventKind? {
        switch type {
        case .keyDown: return .keyDown
        case .keyUp: return .keyUp
        case .flagsChanged: return .flagsChanged
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return .mouseDown
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: return .mouseUp
        case .scrollWheel: return .scroll
        case .pressure, .magnify, .swipe, .rotate, .beginGesture, .endGesture:
            return .trackpadTouch
        default: return nil
        }
    }
}

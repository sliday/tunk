import AppKit
import TunkCore
import TunkEmit

// The app owns no detection and no emission logic. Everything below is a thin
// adapter onto the real subsystems, kept in one file so a rename upstream costs
// one edit here and nothing anywhere else.

enum DetectorFactory {
    /// - Parameter armedTapCounts: the counts with an action bound. Passed
    ///   explicitly rather than left `nil`, because `nil` makes the detector
    ///   derive its firing counts from `config.tapCountToFire`, which is the
    ///   *lowest* armed count. With single and double both bound that would
    ///   arm single only and double taps would never fire.
    /// - Parameter tuning: the DSP constants. Passed rather than defaulted here
    ///   because `TapDetector.tuning` is a `let` — switching experimental lap
    ///   pairing on or off means building a new detector, and this is the one
    ///   place that builds one.
    static func make(config: DetectorConfig, armedTapCounts: Set<Int>,
                     tuning: DSPTuning = .default) -> TapDetecting {
        TapDetector(config: config, tuning: tuning, armedTapCounts: armedTapCounts)
    }
}

extension HotkeySpec {
    /// Build a spec from a recorded `NSEvent`. Function is deliberately not
    /// mapped: fn-plus-key is not a combination VoiceInk records cleanly.
    init(keyCode: UInt16, eventModifiers: NSEvent.ModifierFlags) {
        var mods: HotkeyModifiers = []
        if eventModifiers.contains(.control) { mods.insert(.control) }
        if eventModifiers.contains(.option) { mods.insert(.option) }
        if eventModifiers.contains(.shift) { mods.insert(.shift) }
        if eventModifiers.contains(.command) { mods.insert(.command) }
        // When the key is itself a modifier, its own flag is already raised by
        // pressing it. Keeping it in `modifiers` too would print "Shift+RShift".
        if let role = KeyCodes.modifierRole(for: keyCode) { mods.remove(role.modifier) }
        self.init(keyCode: keyCode, modifiers: mods)
    }

    /// A shortcut is safe to bind when something holds it apart from ordinary
    /// typing: either a held modifier, or the key being a modifier itself.
    var hasModifier: Bool { !modifiers.isEmpty || KeyCodes.isModifier(keyCode) }
}

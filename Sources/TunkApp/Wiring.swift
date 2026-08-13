import AppKit
import TunkCore
import TunkEmit

// The app owns no detection and no emission logic. Everything below is a thin
// adapter onto the real subsystems, kept in one file so a rename upstream costs
// one edit here and nothing anywhere else.

enum DetectorFactory {
    static func make(config: DetectorConfig) -> TapDetecting {
        TapDetector(config: config)
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
        self.init(keyCode: keyCode, modifiers: mods)
    }

    var hasModifier: Bool { !modifiers.isEmpty }
}

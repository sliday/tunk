import CoreGraphics
import Foundation

/// The modifiers a hotkey can carry. Deliberately not `CGEventFlags`: this is a
/// storable, printable, parsable value; the CoreGraphics mapping happens once,
/// in `HotkeySpec.eventFlags`.
public struct HotkeyModifiers: OptionSet, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control  = HotkeyModifiers(rawValue: 1 << 0)
    public static let option   = HotkeyModifiers(rawValue: 1 << 1)
    public static let shift    = HotkeyModifiers(rawValue: 1 << 2)
    public static let command  = HotkeyModifiers(rawValue: 1 << 3)
    public static let function = HotkeyModifiers(rawValue: 1 << 4)

    /// Apple's canonical order for printed shortcuts: fn ⌃ ⌥ ⇧ ⌘.
    static let ordered: [(flag: HotkeyModifiers, name: String, symbol: String, spellings: [String])] = [
        (.function, "Fn",    "\u{1F310}", ["fn", "function"]),
        (.control,  "Ctrl",  "\u{2303}",  ["ctrl", "control", "ctl", "\u{2303}"]),
        (.option,   "Opt",   "\u{2325}",  ["opt", "option", "alt", "\u{2325}"]),
        (.shift,    "Shift", "\u{21E7}",  ["shift", "shft", "\u{21E7}"]),
        (.command,  "Cmd",   "\u{2318}",  ["cmd", "command", "meta", "super", "win", "\u{2318}"]),
    ]

    static func named(_ token: String) -> HotkeyModifiers? {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        for row in ordered where row.spellings.contains(t) { return row.flag }
        return nil
    }

    /// Word form, e.g. `Ctrl+Opt+Cmd`.
    public var description: String {
        Self.ordered.filter { contains($0.flag) }.map(\.name).joined(separator: "+")
    }

    /// Glyph form, e.g. `⌃⌥⌘`. What the menubar shows.
    public var symbols: String {
        Self.ordered.filter { contains($0.flag) }.map(\.symbol).joined()
    }
}

/// A global hotkey: one key plus its modifiers.
///
/// `Codable` as a single human string ("Ctrl+Opt+Cmd+;"), so the settings file
/// holds exactly the text the user pastes into VoiceInk's Second Shortcut field
/// and back. Round-trip is total: key codes with no name print as `#<code>`.
public struct HotkeySpec: Sendable, Hashable, Codable, CustomStringConvertible {
    /// ANSI virtual key code (`kVK_*`).
    public var keyCode: UInt16
    public var modifiers: HotkeyModifiers

    public init(keyCode: UInt16, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // MARK: - Printing

    /// `Ctrl+Opt+Cmd+;` — the form to type into VoiceInk and into Tunk.
    public var description: String {
        let mods = modifiers.description
        let key = KeyCodes.name(for: keyCode)
        return mods.isEmpty ? key : mods + "+" + key
    }

    /// `⌃⌥⌘;` — the form to show in the menubar and settings panel.
    public var symbolicDescription: String {
        modifiers.symbols + KeyCodes.name(for: keyCode)
    }

    // MARK: - Parsing

    /// Parses `Ctrl+Opt+Cmd+;`, `⌃⌥⌘;`, `control-option-command-semicolon`
    /// spellings, and mixtures. Case-insensitive, whitespace-tolerant.
    ///
    /// Scanning is left to right and stops at the first token that is not a
    /// modifier, so a trailing `+` or `-` parses as the key rather than as a
    /// separator.
    public init(parsing raw: String) throws {
        var rest = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { throw EmitError.invalidHotkey(raw, reason: "empty") }

        var mods: HotkeyModifiers = []
        scan: while true {
            rest = rest.trimmingCharacters(in: .whitespaces)
            guard rest.count > 1 else { break scan }

            // Glyph modifier at the head, e.g. "⌘" in "⌃⌥⌘;".
            if let first = rest.first, let m = HotkeyModifiers.named(String(first)) {
                mods.insert(m)
                rest = String(rest.dropFirst())
                if rest.hasPrefix("+") || rest.hasPrefix("-") { rest = String(rest.dropFirst()) }
                continue scan
            }

            // Word modifier followed by a separator, e.g. "Ctrl+" or "control-".
            for separator in ["+", "-"] {
                guard let idx = rest.range(of: separator)?.lowerBound, idx != rest.startIndex else { continue }
                let token = String(rest[rest.startIndex..<idx])
                guard let m = HotkeyModifiers.named(token) else { continue }
                mods.insert(m)
                rest = String(rest[rest.index(after: idx)...])
                continue scan
            }
            break scan
        }

        let keyToken = rest.trimmingCharacters(in: .whitespaces)
        guard !keyToken.isEmpty else {
            throw EmitError.invalidHotkey(raw, reason: "no key after the modifiers")
        }
        guard let code = KeyCodes.code(forName: keyToken) else {
            throw EmitError.invalidHotkey(raw, reason: "unknown key \"\(keyToken)\"")
        }
        self.init(keyCode: code, modifiers: mods)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(parsing: text)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "not a hotkey: \(error)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    // MARK: - CoreGraphics mapping

    /// Left-side device-dependent modifier bits (`NX_DEVICEL*KEYMASK`). Hardware
    /// events always carry them; well-written listeners mask them off, sloppy
    /// ones compare against them. Mimicking hardware is the safer default.
    /// `(modifier, left bit, right bit)` from `IOLLEvent.h`. A listener bound to
    /// Right Shift checks the right bit specifically and ignores the left one,
    /// so emitting the wrong side is the same as emitting nothing.
    static let deviceSideBits: [(mod: HotkeyModifiers, left: UInt64, right: UInt64)] = [
        (.control, 0x0000_0001, 0x0000_2000),  // NX_DEVICE{L,R}CTLKEYMASK
        (.shift,   0x0000_0002, 0x0000_0004),  // NX_DEVICE{L,R}SHIFTKEYMASK
        (.command, 0x0000_0008, 0x0000_0010),  // NX_DEVICE{L,R}CMDKEYMASK
        (.option,  0x0000_0020, 0x0000_0040),  // NX_DEVICE{L,R}ALTKEYMASK
    ]

    static let deviceIndependentBits: [(HotkeyModifiers, CGEventFlags)] = [
        (.control,  .maskControl),
        (.option,   .maskAlternate),
        (.shift,    .maskShift),
        (.command,  .maskCommand),
        (.function, .maskSecondaryFn),
    ]

    /// The flags to stamp on both the key-down and the key-up.
    ///
    /// When the key is itself a modifier (a bare `RShift`, say), that modifier's
    /// own flag has to be asserted too — pressing Right Shift raises the shift
    /// flag, it does not leave it clear.
    public func eventFlags(includeDeviceSide: Bool = true) -> CGEventFlags {
        var held = modifiers
        let role = KeyCodes.modifierRole(for: keyCode)
        if let role { held.insert(role.modifier) }

        var raw: UInt64 = 0
        for (mod, flag) in Self.deviceIndependentBits where held.contains(mod) {
            raw |= flag.rawValue
        }
        if includeDeviceSide {
            for row in Self.deviceSideBits where held.contains(row.mod) {
                // The key itself picks its own side; every other held modifier
                // is emitted left, matching how a keyboard usually reports them.
                let useRight = (role?.modifier == row.mod) && (role?.isRight ?? false)
                raw |= useRight ? row.right : row.left
            }
        }
        return CGEventFlags(rawValue: raw)
    }

    /// The flags for the release half. Identical to `eventFlags` for an ordinary
    /// key, but when the key is itself a modifier its own bits must drop — a
    /// release that still asserts shift is precisely a stuck modifier.
    public func releaseFlags(includeDeviceSide: Bool = true) -> CGEventFlags {
        let down = eventFlags(includeDeviceSide: includeDeviceSide).rawValue
        guard let role = KeyCodes.modifierRole(for: keyCode) else {
            return CGEventFlags(rawValue: down)
        }
        var clear: UInt64 = 0
        for (mod, flag) in Self.deviceIndependentBits where mod == role.modifier {
            clear |= flag.rawValue
        }
        for row in Self.deviceSideBits where row.mod == role.modifier {
            clear |= role.isRight ? row.right : row.left
        }
        // Only drop the bit if nothing else held asserts the same modifier.
        if modifiers.contains(role.modifier) { return CGEventFlags(rawValue: down) }
        return CGEventFlags(rawValue: down & ~clear)
    }

    /// True when this shortcut is a modifier pressed on its own, with nothing
    /// else held. Those need a `flagsChanged` event rather than a key-down, and
    /// they are the fragile case the PRD warns about.
    public var isBareModifier: Bool {
        modifiers.isEmpty && KeyCodes.isModifier(keyCode)
    }

    /// True when the shortcut involves the Right Shift key at all. That key is
    /// reserved for the user's manual VoiceInk primary, so Tunk emitting it
    /// would fight the very binding it is meant to leave alone.
    public var collidesWithVoiceInkPrimary: Bool { keyCode == 60 }

    // MARK: - Suggested defaults

    /// Rare combinations that do not collide with macOS or with common apps.
    /// Rationale lives in the README; see `SuggestedHotkeys`.
    public static let suggested = SuggestedHotkeys.all

    /// First suggestion: `Ctrl+Opt+Cmd+;`.
    public static let recommendedDefault = SuggestedHotkeys.all[0].spec
}

/// The three defaults Tunk offers, with the reason each is safe. The settings
/// panel shows `title` and `why`; the README quotes both.
///
/// All three were checked end to end on this machine: a signed LSUIElement app
/// bundle registered each one with `RegisterEventHotKey` (the Carbon API behind
/// VoiceInk's shortcut layer) and received every one of them within ~10 ms of
/// `HotkeyEmitter.emit()`. See the report for the probe.
///
/// Measured and worth knowing: F13–F20 do **not** work this way. A Carbon hot
/// key registered on F16 never fired for a synthetic event, with any modifier
/// set and any `CGEventSourceStateID`, even though a CGEventTap and an NSEvent
/// global monitor both saw the same event. Do not offer a function-row key as a
/// default, however rare it looks.
public struct SuggestedHotkeys: Sendable {
    public let spec: HotkeySpec
    public let why: String

    public init(spec: HotkeySpec, why: String) {
        self.spec = spec
        self.why = why
    }

    public var title: String { spec.description }
    public var symbols: String { spec.symbolicDescription }

    public static let all: [SuggestedHotkeys] = [
        SuggestedHotkeys(
            spec: HotkeySpec(keyCode: 41, modifiers: [.control, .option, .command]),   // ;
            why: """
                 Ctrl+Opt+Cmd+; — macOS ships no system shortcut on the semicolon key, and \
                 no stock app binds it with three modifiers. Semicolon sits on every Mac \
                 keyboard, so the user can also press it while recording the Second Shortcut \
                 in VoiceInk. Reachable one-handed on the right side. Verified received by a \
                 Carbon hot key listener.
                 """),
        SuggestedHotkeys(
            spec: HotkeySpec(keyCode: 42, modifiers: [.control, .option, .command]),   // \
            why: """
                 Ctrl+Opt+Cmd+\\ — backslash has no macOS system binding. A few editors use \
                 Cmd+\\ for split panes, but none of them add Ctrl and Opt on top. Take this \
                 one if a text expander already owns the semicolon combination. Verified \
                 received by a Carbon hot key listener.
                 """),
        SuggestedHotkeys(
            spec: HotkeySpec(keyCode: 39, modifiers: [.control, .option, .shift, .command]), // '
            why: """
                 Ctrl+Opt+Shift+Cmd+' — all four modifiers, the so-called hyper key. macOS \
                 reserves nothing on four-modifier chords and apps almost never bind them, \
                 so collision risk is the lowest of the three. Two catches: it is awkward to \
                 press by hand while recording it in VoiceInk, and Karabiner users who \
                 already remap Caps Lock to hyper may collide. Verified received by a Carbon \
                 hot key listener.
                 """),
    ]
}

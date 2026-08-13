import Foundation

/// ANSI virtual key codes (`kVK_*` from Carbon's `Events.h`) with the names a
/// human types into a settings field.
///
/// The table is the single source of truth for both directions, so
/// `HotkeySpec.description` and `HotkeySpec(parsing:)` cannot drift apart.
/// Anything not in the table still round-trips through the `#<code>` escape.
public enum KeyCodes {
    /// `(code, canonical display name, extra accepted spellings)`.
    /// Canonical name is what `description` prints; every spelling parses.
    static let table: [(code: UInt16, name: String, aliases: [String])] = [
        (0, "A", []), (1, "S", []), (2, "D", []), (3, "F", []), (4, "H", []),
        (5, "G", []), (6, "Z", []), (7, "X", []), (8, "C", []), (9, "V", []),
        (11, "B", []), (12, "Q", []), (13, "W", []), (14, "E", []), (15, "R", []),
        (16, "Y", []), (17, "T", []),
        (18, "1", []), (19, "2", []), (20, "3", []), (21, "4", []), (22, "6", []),
        (23, "5", []), (25, "9", []), (26, "7", []), (28, "8", []), (29, "0", []),
        (24, "=", ["equal", "equals", "plus", "+"]),
        (27, "-", ["minus", "hyphen", "dash", "underscore", "_"]),
        (30, "]", ["rightbracket", "closebracket", "}"]),
        (31, "O", []), (32, "U", []),
        (33, "[", ["leftbracket", "openbracket", "{"]),
        (34, "I", []), (35, "P", []),
        (36, "Return", ["enter", "cr", "\u{21A9}"]),
        (37, "L", []), (38, "J", []),
        (39, "'", ["quote", "apostrophe", "\"", "doublequote"]),
        (40, "K", []),
        (41, ";", ["semicolon", ":", "colon"]),
        (42, "\\", ["backslash", "|", "pipe"]),
        (43, ",", ["comma", "<", "lessthan"]),
        (44, "/", ["slash", "forwardslash", "?", "questionmark"]),
        (45, "N", []), (46, "M", []),
        (47, ".", ["period", "dot", ">", "greaterthan"]),
        (48, "Tab", ["\u{21E5}"]),
        (49, "Space", ["spacebar", "spc"]),
        (50, "`", ["grave", "backtick", "tilde", "~"]),
        (51, "Delete", ["backspace", "del", "\u{232B}"]),
        (53, "Escape", ["esc", "\u{238B}"]),
        (65, "KeypadDecimal", ["numpaddecimal", "kp."]),
        (67, "KeypadMultiply", ["numpadmultiply", "kp*"]),
        (69, "KeypadPlus", ["numpadplus", "kp+"]),
        (71, "KeypadClear", ["numpadclear", "clear"]),
        (75, "KeypadDivide", ["numpaddivide", "kp/"]),
        (76, "KeypadEnter", ["numpadenter", "kpenter"]),
        (78, "KeypadMinus", ["numpadminus", "kp-"]),
        (81, "KeypadEquals", ["numpadequals", "kp="]),
        (82, "Keypad0", ["numpad0"]), (83, "Keypad1", ["numpad1"]),
        (84, "Keypad2", ["numpad2"]), (85, "Keypad3", ["numpad3"]),
        (86, "Keypad4", ["numpad4"]), (87, "Keypad5", ["numpad5"]),
        (88, "Keypad6", ["numpad6"]), (89, "Keypad7", ["numpad7"]),
        (91, "Keypad8", ["numpad8"]), (92, "Keypad9", ["numpad9"]),
        (96, "F5", []), (97, "F6", []), (98, "F7", []), (99, "F3", []),
        (100, "F8", []), (101, "F9", []), (103, "F11", []), (105, "F13", []),
        (106, "F16", []), (107, "F14", []), (109, "F10", []), (111, "F12", []),
        (113, "F15", []), (118, "F4", []), (120, "F2", []), (122, "F1", []),
        (64, "F17", []), (79, "F18", []), (80, "F19", []), (90, "F20", []),
        (114, "Help", ["insert"]),
        (115, "Home", ["\u{2196}"]),
        (116, "PageUp", ["pgup", "\u{21DE}"]),
        (117, "ForwardDelete", ["fwddelete", "\u{2326}"]),
        (119, "End", ["\u{2198}"]),
        (121, "PageDown", ["pgdn", "pagedn", "\u{21DF}"]),
        (123, "Left", ["leftarrow", "\u{2190}"]),
        (124, "Right", ["rightarrow", "\u{2192}"]),
        (125, "Down", ["downarrow", "\u{2193}"]),
        (126, "Up", ["uparrow", "\u{2191}"]),
    ]

    static let nameForCode: [UInt16: String] = {
        var out: [UInt16: String] = [:]
        for row in table { out[row.code] = row.name }
        return out
    }()

    static let codeForName: [String: UInt16] = {
        var out: [String: UInt16] = [:]
        for row in table {
            out[row.name.lowercased()] = row.code
            for alias in row.aliases { out[alias.lowercased()] = row.code }
        }
        return out
    }()

    /// Display name for a key code. Unknown codes come back as `#<code>`, which
    /// `code(forName:)` accepts, so every spec round-trips.
    public static func name(for code: UInt16) -> String {
        nameForCode[code] ?? "#\(code)"
    }

    /// Key code for a typed name. Case-insensitive. Accepts `#<code>`.
    public static func code(forName raw: String) -> UInt16? {
        let token = raw.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return nil }
        if token.hasPrefix("#"), let n = UInt16(token.dropFirst()) { return n }
        return codeForName[token.lowercased()]
    }

    /// Every code the table knows, ascending. Used by the settings picker.
    public static var knownCodes: [UInt16] { nameForCode.keys.sorted() }
}

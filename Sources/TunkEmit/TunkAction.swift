import Foundation

/// What a confirmed double-tap does.
///
/// Modelled on iPhone Back Tap: the gesture is fixed, the action is a list the
/// user picks from. `.hotkey` is the original path and stays the default, so an
/// install that predates this type behaves exactly as it did.
///
/// ## Codable
///
/// Encodes as a tagged object, `{"kind":"hotkey","hotkey":"Ctrl+Opt+Cmd+;"}`.
/// Decoding also accepts a bare `HotkeySpec` string, which is what settings
/// written before this type existed contain — see `init(from:)`. That is the
/// whole migration: an old settings file keeps working and the user's chosen
/// combination survives, rather than being reset to a default.
public enum TunkAction: Codable, Hashable, Sendable {
    /// Post a global hotkey through `HotkeyEmitter`. The VoiceInk path.
    case hotkey(HotkeySpec)
    /// Run a macOS Shortcut by name, via `/usr/bin/shortcuts run <name>`.
    case shortcut(name: String)
    /// Detect, count, draw the monitor trace — and do nothing else. Useful while
    /// tuning sensitivity without firing anything at the frontmost app.
    case none

    // MARK: - Description

    /// One line for the menubar and the panel's summary readout.
    public var summary: String {
        switch self {
        case .hotkey(let spec):   return spec.symbolicDescription
        case .shortcut(let name): return name.isEmpty ? "no Shortcut chosen" : name
        case .none:               return "nothing"
        }
    }

    /// The hotkey this action posts, if any. Nil for every other kind — callers
    /// that need a spec must handle its absence rather than substituting one.
    public var hotkeySpec: HotkeySpec? {
        if case .hotkey(let spec) = self { return spec }
        return nil
    }

    public var shortcutName: String? {
        if case .shortcut(let name) = self { return name }
        return nil
    }

    /// True when running this action reaches outside Tunk. `.none` does not, and
    /// a `.shortcut` with an empty name cannot.
    public var isRunnable: Bool {
        switch self {
        case .hotkey:             return true
        case .shortcut(let name): return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .none:               return false
        }
    }

    // MARK: - Coding

    /// Stable tags. These end up in the user's settings file, so they are
    /// written out once here and never derived from the case names.
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case hotkey, shortcut, none
    }

    public var kind: Kind {
        switch self {
        case .hotkey:   return .hotkey
        case .shortcut: return .shortcut
        case .none:     return .none
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, hotkey, name
    }

    public init(from decoder: Decoder) throws {
        // Legacy first, because it is the cheapest test and the one that must
        // never regress: settings written before `TunkAction` existed hold a
        // bare hotkey string like "Ctrl+Opt+Cmd+;".
        if let single = try? decoder.singleValueContainer(),
           let text = try? single.decode(String.self) {
            do {
                self = .hotkey(try HotkeySpec(parsing: text))
                return
            } catch {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath,
                          debugDescription: "not a legacy hotkey action: \(error)"))
            }
        }

        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .hotkey:
            self = .hotkey(try c.decode(HotkeySpec.self, forKey: .hotkey))
        case .shortcut:
            self = .shortcut(name: try c.decode(String.self, forKey: .name))
        case .none:
            self = .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .hotkey(let spec):   try c.encode(spec, forKey: .hotkey)
        case .shortcut(let name): try c.encode(name, forKey: .name)
        case .none:               break
        }
    }

    // MARK: - Settings migration

    /// Works out the stored action from the two things a settings store might
    /// hold. Lives here, not in the app, so it can be tested without a running
    /// `UserDefaults`.
    ///
    /// - Parameters:
    ///   - actionData: whatever is under the `action` key, if anything.
    ///   - legacyHotkeyText: whatever is under the old `hotkey` key, a bare
    ///     combination string written by builds that predate this type.
    ///
    /// The order is the point. A user upgrading from a hotkey-only build has no
    /// `action` and a perfectly good `hotkey`; they keep their combination.
    /// Falling through to `.hotkey(.recommendedDefault)` happens only on a
    /// genuinely fresh install, or when both stored values are unreadable.
    public static func restored(actionData: Data?,
                                legacyHotkeyText: String?,
                                decoder: JSONDecoder = JSONDecoder()) -> TunkAction {
        if let actionData, let stored = try? decoder.decode(TunkAction.self, from: actionData) {
            return stored
        }
        if let legacyHotkeyText, let spec = try? HotkeySpec(parsing: legacyHotkeyText) {
            return .hotkey(spec)
        }
        return .hotkey(.recommendedDefault)
    }
}

import Foundation

/// What a confirmed tap gesture does.
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
    ///
    /// `wasListedWhenBound` records whether the name was present in
    /// `shortcuts list` at the moment the user picked it. Months later, when a
    /// name no longer resolves, that one bit is the difference between "you
    /// renamed or deleted it" and "this never existed", which are different
    /// sentences to show the user. It defaults to `false` so a migrated or
    /// hand-written binding claims nothing it cannot back up.
    case shortcut(name: String, wasListedWhenBound: Bool = false)
    /// Detect, count, draw the monitor trace — and do nothing else. Useful while
    /// tuning sensitivity without firing anything at the frontmost app.
    case none

    // MARK: - Description

    /// One line for the menubar and the panel's summary readout.
    public var summary: String {
        switch self {
        case .hotkey(let spec):      return spec.symbolicDescription
        case .shortcut(let name, _): return name.isEmpty ? "no Shortcut chosen" : name
        case .none:                  return "nothing"
        }
    }

    /// The hotkey this action posts, if any. Nil for every other kind — callers
    /// that need a spec must handle its absence rather than substituting one.
    public var hotkeySpec: HotkeySpec? {
        if case .hotkey(let spec) = self { return spec }
        return nil
    }

    public var shortcutName: String? {
        if case .shortcut(let name, _) = self { return name }
        return nil
    }

    /// True when this binding was made by picking from a listing that actually
    /// contained the name. See the `.shortcut` case for why it is kept.
    public var shortcutWasListedWhenBound: Bool {
        if case .shortcut(_, let listed) = self { return listed }
        return false
    }

    /// True when running this action reaches outside Tunk. `.none` does not, and
    /// a `.shortcut` with an empty name cannot.
    public var isRunnable: Bool {
        switch self {
        case .hotkey:                return true
        case .shortcut(let name, _): return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .none:                  return false
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
        case kind, hotkey, name, wasListed
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
            // Absent in blobs written before the stale-name check existed. False
            // is the safe reading: it claims nothing about a listing we never saw.
            self = .shortcut(name: try c.decode(String.self, forKey: .name),
                             wasListedWhenBound: try c.decodeIfPresent(Bool.self,
                                                                       forKey: .wasListed) ?? false)
        case .none:
            self = .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .hotkey(let spec):
            try c.encode(spec, forKey: .hotkey)
        case .shortcut(let name, let wasListed):
            try c.encode(name, forKey: .name)
            if wasListed { try c.encode(true, forKey: .wasListed) }
        case .none:
            break
        }
    }

}

/// One action per tap count, the iPhone Back Tap model where Double Tap and
/// Triple Tap are separate rows.
///
/// Single and double are surfaced. Triple is representable and persists
/// correctly, so wiring it later is a UI change and a detector change, not a
/// change to this type or to the settings file format.
///
/// ## Why single tap defaults to `.none`
///
/// Every mug set down, every footfall and every hard keystroke is a single
/// transient. The whole false-positive defence rests on requiring two
/// deliberate onsets close together. So single tap ships unbound: having it is
/// the owner's call, arming it must be the user's.
public struct ActionBindings: Codable, Hashable, Sendable {
    /// Counts the settings panel offers today.
    public static let wiredCounts = [2, 1]
    /// Counts this type will store and reload without loss. Triple is here so
    /// enabling it later does not need a migration.
    public static let representableCounts = [1, 2, 3]

    private var byCount: [Int: TunkAction]

    public init(_ byCount: [Int: TunkAction] = [:]) {
        self.byCount = byCount.filter { $0.value != .none }
    }

    /// Fresh install: double tap posts the recommended hotkey, single tap does
    /// nothing.
    public static let `default` = ActionBindings([2: .hotkey(.recommendedDefault)])

    /// The action bound to a tap count. Unbound counts read as `.none`, which is
    /// what makes "nothing is bound to that count" a quiet no-op rather than an
    /// error the user has to dismiss.
    public subscript(count: Int) -> TunkAction {
        get { byCount[count] ?? .none }
        set {
            if newValue == .none { byCount.removeValue(forKey: count) }
            else { byCount[count] = newValue }
        }
    }

    /// Counts with something actually bound, ascending.
    public var boundCounts: [Int] { byCount.keys.sorted() }

    /// True when any bound action reaches outside Tunk.
    public var isAnythingBound: Bool { byCount.values.contains { $0.isRunnable } }

    /// Every hotkey this configuration can post. The app preflights these at
    /// launch so a permission problem shows up before a tap does.
    public var hotkeySpecs: [HotkeySpec] {
        boundCounts.compactMap { byCount[$0]?.hotkeySpec }
    }

    /// Every Shortcut name this configuration can run, with its count.
    public var shortcutBindings: [(count: Int, name: String, wasListedWhenBound: Bool)] {
        boundCounts.compactMap { count in
            guard let name = byCount[count]?.shortcutName else { return nil }
            return (count, name, byCount[count]?.shortcutWasListedWhenBound ?? false)
        }
    }

    // MARK: - Coding

    /// Keyed by the count as a string. `Dictionary<Int, _>` encodes as a flat
    /// JSON array, which is unreadable in a settings file and brittle to hand
    /// edit, so the keys are written out properly.
    private struct CountKey: CodingKey {
        var stringValue: String
        var intValue: Int? { Int(stringValue) }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.stringValue = String(intValue) }
        init(_ count: Int) { self.stringValue = String(count) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CountKey.self)
        var out: [Int: TunkAction] = [:]
        for key in c.allKeys {
            guard let count = key.intValue else { continue }
            out[count] = try c.decode(TunkAction.self, forKey: key)
        }
        self.init(out)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CountKey.self)
        for count in boundCounts {
            try c.encode(byCount[count], forKey: CountKey(count))
        }
    }

    // MARK: - Settings migration

    /// Works out the stored bindings from the three shapes a settings store
    /// might hold. Lives here, not in the app, so it can be tested without a
    /// running `UserDefaults`.
    ///
    /// - Parameters:
    ///   - bindingsData: the `actionBindings` key, the current shape.
    ///   - actionData: the `action` key, a single `TunkAction` from the build
    ///     that had one action and no tap count.
    ///   - legacyHotkeyText: the `hotkey` key, a bare combination string from
    ///     the builds before that.
    ///
    /// Order matters, and so does where a migrated action lands: an existing
    /// single action becomes the **double** tap binding, with single left at
    /// `.none`. Nobody gets a single-tap action they did not ask for, and nobody
    /// loses the binding they had.
    public static func restored(bindingsData: Data?,
                                actionData: Data?,
                                legacyHotkeyText: String?,
                                decoder: JSONDecoder = JSONDecoder()) -> ActionBindings {
        if let bindingsData,
           let stored = try? decoder.decode(ActionBindings.self, from: bindingsData) {
            return stored
        }
        if let actionData, let action = try? decoder.decode(TunkAction.self, from: actionData) {
            return ActionBindings([2: action])
        }
        if let legacyHotkeyText, let spec = try? HotkeySpec(parsing: legacyHotkeyText) {
            return ActionBindings([2: .hotkey(spec)])
        }
        return .default
    }
}

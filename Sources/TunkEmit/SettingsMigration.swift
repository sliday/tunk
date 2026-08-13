import Foundation
import TunkCore

/// Brings a `DetectorConfig` stored by an older build up to the current one,
/// and says what it changed.
///
/// New defaults only ever reach a fresh install. Anyone who ran an earlier build
/// keeps whatever was persisted then, which by now can mean a gate window too
/// short to cover typing and a tap-spacing value that the detector silently
/// clamps. Both work against the metric the PRD calls make-or-break, and neither
/// is visible to the user.
///
/// Two rules shape what this is allowed to touch:
///
///  1. Only values that are **unsafe or incoherent** move. A setting the user
///     deliberately chose and that still works is left exactly as it is, and
///     nothing here touches hotkeys, Shortcut names or action bindings at all.
///  2. Nothing moves **silently**. Every change comes back as a `Note` the panel
///     shows, in the same place the detector's own coherence issues appear.
///
/// It lives in TunkEmit because that is where it can be tested without a running
/// `UserDefaults` or a live detector. It reads as detector code and would sit
/// more naturally in TunkCore — flagged to the lead rather than moved.
public enum SettingsMigration {

    /// Gate windows below this leave gaps between keystrokes that typing can
    /// fire through. The PRD's own starting range is 150–200 ms, and a stored
    /// value under it predates that guidance.
    public static let minimumSafeGateNs: Int64 = 150_000_000

    /// One thing the migration changed, in words the panel prints verbatim.
    public struct Note: Sendable, Equatable, Identifiable, CustomStringConvertible {
        public var field: String
        public var was: String
        public var now: String
        public var why: String

        public var id: String { field }

        public init(field: String, was: String, now: String, why: String) {
            self.field = field
            self.was = was
            self.now = now
            self.why = why
        }

        public var description: String { "\(field): was \(was), now \(now). \(why)" }
    }

    public struct Result: Sendable, Equatable {
        public var config: DetectorConfig
        public var notes: [Note]
        public var changed: Bool { !notes.isEmpty }
    }

    /// - Parameters:
    ///   - stored: what was loaded from the settings store.
    ///   - defaults: the current shipped defaults, injectable for tests.
    public static func migrate(_ stored: DetectorConfig,
                               defaults: DetectorConfig = .default) -> Result {
        var out = stored
        var notes: [Note] = []

        // 1. A gate too short to do its job. This is the unsafe one: the gate is
        //    the only thing standing between typing and a false trigger.
        if out.gateWindowNs < minimumSafeGateNs {
            notes.append(Note(
                field: "Gate window",
                was: ms(out.gateWindowNs), now: ms(defaults.gateWindowNs),
                why: "Below \(ms(minimumSafeGateNs)) the gate stops covering the gap between "
                   + "keystrokes, so typing can fire a tap. Raised to the current default."))
            out.gateWindowNs = defaults.gateWindowNs
        }

        // 2. An incoherent join window. Clamping it down to an old, shorter
        //    confirm window would quietly narrow the spacing the user is allowed
        //    between taps, so raise the confirm window to the current default
        //    first and let the clamp land there instead. That keeps as much of
        //    the user's intent as the invariant allows.
        if out.maxInterTapNs > out.confirmWindowNs,
           out.confirmWindowNs < defaults.confirmWindowNs {
            notes.append(Note(
                field: "Confirm window",
                was: ms(out.confirmWindowNs), now: ms(defaults.confirmWindowNs),
                why: "Your tap spacing of \(ms(out.maxInterTapNs)) was wider than the confirm "
                   + "window, which the detector has to clamp. Widening the window instead "
                   + "keeps more of the spacing you had."))
            out.confirmWindowNs = defaults.confirmWindowNs
        }

        // 3. Whatever is still incoherent gets the detector's own clamp, and the
        //    detector's own words for it.
        let issues = out.coherenceIssues
        if !issues.isEmpty {
            let coherent = out.madeCoherent()
            for issue in issues {
                notes.append(Note(
                    field: label(for: issue.field),
                    was: describeField(issue.field, in: out),
                    now: describeField(issue.field, in: coherent),
                    why: sentence(issue.reason)))
            }
            out = coherent
        }

        return Result(config: out, notes: notes)
    }

    /// The detector names its fields as code identifiers. The panel shows these
    /// to a user, so `maxInterTapNs` becomes the words the slider uses. The
    /// table lives in TunkCore next to the issues themselves, so this and the
    /// panel cannot drift apart.
    private static func label(for field: String) -> String {
        DetectorConfig.fieldLabel(for: field)
    }

    /// The detector's reasons are written as clause fragments. The panel prints
    /// them as sentences.
    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst() + "."
    }

    /// Best effort, and honest when it cannot: the coherence issues name their
    /// own field, and only the ones this build knows about can be printed as a
    /// value rather than as the issue's own text.
    private static func describeField(_ field: String, in config: DetectorConfig) -> String {
        switch field {
        case "maxInterTapNs":   return ms(config.maxInterTapNs)
        case "minInterTapNs":   return ms(config.minInterTapNs)
        case "confirmWindowNs": return ms(config.confirmWindowNs)
        case "gateWindowNs":    return ms(config.gateWindowNs)
        case "refractoryNs":    return ms(config.refractoryNs)
        default:                return "adjusted"
        }
    }

    private static func ms(_ ns: Int64) -> String {
        "\(Int((Double(ns) / 1_000_000).rounded())) ms"
    }
}

import Foundation
import TunkCore

/// Config loading and the named-parameter table the sweep drives.
///
/// A config file is a partial override of `DetectorConfig.default`: any key you
/// leave out keeps the default, so a tuning file can be three lines long. Every
/// key is validated, and an unknown key is an error rather than a silent no-op —
/// a typo in a sweep script must never masquerade as a result.
enum ConfigIO {
    static func load(url: URL) throws -> DetectorConfig {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.usage("config file \(url.path) is not a JSON object")
        }
        var cfg = DetectorConfig.default
        // A config file describes a whole front end too, so start from the
        // shipped filter design rather than whatever a previous load left here.
        DetectorFactory.tuning = .default
        for (key, value) in obj {
            guard let param = ConfigParam(name: key) else {
                throw CLIError.usage("unknown config key '\(key)'. Known keys: "
                                     + ConfigParam.allNames.joined(separator: ", "))
            }
            if value is NSNull {
                if param == .calibratedThreshold { cfg.calibratedThreshold = nil; continue }
                throw CLIError.usage("config key '\(key)' cannot be null")
            }
            guard let n = (value as? NSNumber)?.doubleValue else {
                throw CLIError.usage("config key '\(key)' must be a number")
            }
            // A `...Ms` key is milliseconds; the struct stores nanoseconds. Missing
            // this turned a 220 ms gate into a 220 ns gate, which reads as "the gate
            // stopped working" in the report.
            param.set(&cfg, n * ConfigParam.scale(forName: key))
        }
        try validate(cfg)
        return cfg
    }

    static func validate(_ c: DetectorConfig) throws {
        if c.minInterTapNs >= c.maxInterTapNs {
            throw CLIError.usage("minInterTapNs (\(c.minInterTapNs)) must be below maxInterTapNs (\(c.maxInterTapNs))")
        }
        if c.tapCountToFire < 1 {
            throw CLIError.usage("tapCountToFire must be at least 1")
        }
        if c.effectiveThreshold <= 0 {
            throw CLIError.usage("effective threshold is \(c.effectiveThreshold); it must be positive")
        }
    }

    static func describe(_ c: DetectorConfig) -> String {
        var out = ""
        for p in ConfigParam.allCases {
            out += "  \(Reporter.pad(p.name, 22)) \(p.display(c))\n"
        }
        out += "  \(Reporter.pad("effectiveThreshold", 22)) \(String(format: "%.4f", c.effectiveThreshold))\n"
        return out
    }

    /// One line naming the front end, for the report's warnings. Only ever
    /// printed when the front end is NOT the shipped one — a run that says
    /// nothing about the front end ran the shipped one.
    static func describeFrontEnd(_ t: DSPTuning) -> String {
        var parts: [String] = []
        let d = DSPTuning.default
        if t.highPassHz != d.highPassHz { parts.append(String(format: "highPass %.1f Hz", t.highPassHz)) }
        if t.resonatorHz != d.resonatorHz || t.resonatorQ != d.resonatorQ {
            parts.append(t.resonatorHz > 0
                         ? String(format: "resonator %.1f Hz Q %.2f", t.resonatorHz, t.resonatorQ)
                         : "resonator off")
        }
        if t.minThresholdG != d.minThresholdG { parts.append(String(format: "minThreshold %.4f g", t.minThresholdG)) }
        // A run with retrospective pairing on is not a run of the shipped
        // detector, and the report has to say so on its own without anyone
        // remembering to mention it.
        if t.pairRescueEnabled {
            parts.append(String(format: "pair rescue on (candFrac %.2f, cosMin %.2f, rank %@, "
                                       + "rectMax %.2f, anchorFrac %.2f, pol window %d, "
                                       + "lookahead %d)",
                                t.pairRescueCandidateFraction, t.pairRescueCosMin,
                                t.pairRescueRankByRect ? "rect" : "amplitude",
                                t.pairRescueRectMax, t.pairRescueAnchorFraction,
                                t.polarizationWindowSamples, t.polarizationLookaheadSamples))
        }
        return parts.isEmpty ? "shipped" : parts.joined(separator: ", ")
    }
}

/// One tunable, addressable by name. Millisecond aliases exist because nobody
/// wants to type nanoseconds into a sweep by hand.
enum ConfigParam: String, CaseIterable {
    case sensitivity
    case calibratedThreshold
    case defaultThreshold
    case gateWindowNs
    case minInterTapNs
    case maxInterTapNs
    case confirmWindowNs
    case refractoryNs
    case tapCountToFire
    case onsetCeilingG
    case motionGateG
    // Front-end filter design. These live in `DSPTuning`, not `DetectorConfig`,
    // so they write `DetectorFactory.tuning` rather than the config struct —
    // see `isFrontEnd`. They ship at their default values, and a run that does
    // not name one is a run of the shipped front end.
    case highPassHz
    case resonatorHz
    case resonatorQ
    case minThresholdG
    // The re-arm condition, in full. `Detector.swift` re-arms when the envelope
    // falls under `releaseFraction * threshold` AND `onsetDebounceNs` has
    // passed, and neither was reachable here. Four separate critics ran into
    // that wall and reported it: both constants were fitted when the chain gain
    // was 0.68 and the threshold 0.032 g, and at the resonator operating point
    // the gain is 0.0789 and the threshold 0.011 g, so 0.4 sits at a different
    // place on the envelope than where it was chosen. A referee that cannot
    // grade the constant its own root-cause analysis names is not a referee.
    case releaseFraction
    case onsetDebounceNs
    // Retrospective pairing ranked by polarization. Off unless a config names
    // `pairRescueEnabled`, so a run that does not name it is a run of the
    // shipped detector.
    case pairRescueEnabled
    case pairRescueCandidateFraction
    case pairRescueCosMin
    case pairRescueRankByRect
    case pairRescueRectMax
    case pairRescueAnchorFraction
    case polarizationWindowSamples
    case polarizationLookaheadSamples

    /// Whether this parameter belongs to the front end rather than to
    /// `DetectorConfig`. The distinction is real: a `DetectorConfig` written by
    /// the settings panel cannot express these, and a report's `config` block
    /// does not carry them, which is why `Reporter.build` names a non-default
    /// front end in the warnings instead.
    var isFrontEnd: Bool {
        switch self {
        case .highPassHz, .resonatorHz, .resonatorQ, .minThresholdG,
             .releaseFraction, .onsetDebounceNs,
             .pairRescueEnabled, .pairRescueCandidateFraction, .pairRescueCosMin,
             .pairRescueRankByRect, .pairRescueRectMax, .pairRescueAnchorFraction,
             .polarizationWindowSamples, .polarizationLookaheadSamples: return true
        default: return false
        }
    }

    /// Accepts the canonical name or its `...Ms` alias for the ns fields.
    init?(name: String) {
        if let p = ConfigParam(rawValue: name) { self = p; return }
        for p in ConfigParam.allCases where p.msAlias == name { self = p; return }
        return nil
    }

    var name: String { rawValue }

    var msAlias: String? {
        guard rawValue.hasSuffix("Ns") else { return nil }
        return String(rawValue.dropLast(2)) + "Ms"
    }

    var isNanoseconds: Bool { rawValue.hasSuffix("Ns") }

    static var allNames: [String] {
        allCases.flatMap { [$0.name] + ($0.msAlias.map { [$0] } ?? []) }
    }

    /// Whether `value` given under this name is in ms and needs scaling.
    static func scale(forName name: String) -> Double {
        guard let p = ConfigParam(name: name), p.isNanoseconds, p.msAlias == name else { return 1 }
        return 1_000_000
    }

    func set(_ c: inout DetectorConfig, _ v: Double) {
        switch self {
        case .sensitivity: c.sensitivity = v
        case .calibratedThreshold: c.calibratedThreshold = v
        case .defaultThreshold: c.defaultThreshold = v
        case .gateWindowNs: c.gateWindowNs = Int64(v.rounded())
        case .minInterTapNs: c.minInterTapNs = Int64(v.rounded())
        case .maxInterTapNs: c.maxInterTapNs = Int64(v.rounded())
        case .confirmWindowNs: c.confirmWindowNs = Int64(v.rounded())
        case .refractoryNs: c.refractoryNs = Int64(v.rounded())
        case .tapCountToFire: c.tapCountToFire = Int(v.rounded())
        // A ceiling of 0 or less means "no ceiling", so a sweep can turn it off
        // by sweeping through zero rather than needing a separate flag.
        case .onsetCeilingG: c.onsetCeilingG = v > 0 ? v : nil
        case .motionGateG: c.motionGateG = v
        case .releaseFraction: DetectorFactory.tuning.releaseFraction = v
        case .onsetDebounceNs: DetectorFactory.tuning.onsetDebounceNs = Int64(v)
        case .highPassHz: DetectorFactory.tuning.highPassHz = v
        // Zero means the stage is absent, so a sweep can start at "shipped".
        case .resonatorHz: DetectorFactory.tuning.resonatorHz = max(0, v)
        case .resonatorQ: DetectorFactory.tuning.resonatorQ = v
        case .minThresholdG: DetectorFactory.tuning.minThresholdG = v
        // Booleans over a numeric channel: anything above zero is on, so a
        // sweep can walk through the switch like any other parameter.
        case .pairRescueEnabled: DetectorFactory.tuning.pairRescueEnabled = v > 0
        case .pairRescueCandidateFraction: DetectorFactory.tuning.pairRescueCandidateFraction = v
        case .pairRescueCosMin: DetectorFactory.tuning.pairRescueCosMin = v
        case .pairRescueRankByRect: DetectorFactory.tuning.pairRescueRankByRect = v > 0
        case .pairRescueRectMax: DetectorFactory.tuning.pairRescueRectMax = v
        case .pairRescueAnchorFraction: DetectorFactory.tuning.pairRescueAnchorFraction = v
        case .polarizationWindowSamples:
            DetectorFactory.tuning.polarizationWindowSamples = Int(v.rounded())
        case .polarizationLookaheadSamples:
            DetectorFactory.tuning.polarizationLookaheadSamples = Int(v.rounded())
        }
    }

    func get(_ c: DetectorConfig) -> Double? {
        switch self {
        case .sensitivity: return c.sensitivity
        case .calibratedThreshold: return c.calibratedThreshold
        case .defaultThreshold: return c.defaultThreshold
        case .gateWindowNs: return Double(c.gateWindowNs)
        case .minInterTapNs: return Double(c.minInterTapNs)
        case .maxInterTapNs: return Double(c.maxInterTapNs)
        case .confirmWindowNs: return Double(c.confirmWindowNs)
        case .refractoryNs: return Double(c.refractoryNs)
        case .tapCountToFire: return Double(c.tapCountToFire)
        case .onsetCeilingG: return c.onsetCeilingG ?? 0
        case .motionGateG: return c.motionGateG
        case .releaseFraction: return DetectorFactory.tuning.releaseFraction
        case .onsetDebounceNs: return Double(DetectorFactory.tuning.onsetDebounceNs)
        case .highPassHz: return DetectorFactory.tuning.highPassHz
        case .resonatorHz: return DetectorFactory.tuning.resonatorHz
        case .resonatorQ: return DetectorFactory.tuning.resonatorQ
        case .minThresholdG: return DetectorFactory.tuning.minThresholdG
        case .pairRescueEnabled: return DetectorFactory.tuning.pairRescueEnabled ? 1 : 0
        case .pairRescueCandidateFraction: return DetectorFactory.tuning.pairRescueCandidateFraction
        case .pairRescueCosMin: return DetectorFactory.tuning.pairRescueCosMin
        case .pairRescueRankByRect: return DetectorFactory.tuning.pairRescueRankByRect ? 1 : 0
        case .pairRescueRectMax: return DetectorFactory.tuning.pairRescueRectMax
        case .pairRescueAnchorFraction: return DetectorFactory.tuning.pairRescueAnchorFraction
        case .polarizationWindowSamples:
            return Double(DetectorFactory.tuning.polarizationWindowSamples)
        case .polarizationLookaheadSamples:
            return Double(DetectorFactory.tuning.polarizationLookaheadSamples)
        }
    }

    func display(_ c: DetectorConfig) -> String {
        guard let v = get(c) else { return "nil" }
        if isNanoseconds { return String(format: "%.1f ms", v / 1e6) }
        return String(format: "%g", v)
    }
}

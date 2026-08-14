import Foundation
import TunkCore

/// Config loading and the named-parameter table the sweep drives.
///
/// A config file is a partial override of `DetectorConfig.default`: any key you
/// leave out keeps the default, so a tuning file can be three lines long. Every
/// key is validated, and an unknown key is an error rather than a silent no-op —
/// a typo in a sweep script must never masquerade as a result.
enum ConfigIO {
    /// A config file may also carry front-end keys, which live in `DSPTuning`
    /// rather than `DetectorConfig`. They are kept apart on purpose:
    /// `DetectorConfig` is what the settings panel writes and the user owns,
    /// `DSPTuning` is filter design. The harness needs to reach both from one
    /// file so a front-end variant can be graded the same way a threshold is.
    static func load(url: URL) throws -> DetectorConfig {
        try loadFull(url: url).config
    }

    static func loadFull(url: URL) throws -> (config: DetectorConfig, tuning: DSPTuning) {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.usage("config file \(url.path) is not a JSON object")
        }
        var cfg = DetectorConfig.default
        var tuning = DSPTuning.default
        for (key, value) in obj {
            if let t = TuningParam(rawValue: key) {
                guard let n = (value as? NSNumber)?.doubleValue else {
                    throw CLIError.usage("config key '\(key)' must be a number")
                }
                try t.set(&tuning, n)
                continue
            }
            guard let param = ConfigParam(name: key) else {
                throw CLIError.usage("unknown config key '\(key)'. Known keys: "
                                     + (ConfigParam.allNames + TuningParam.allNames)
                                        .joined(separator: ", "))
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
        return (cfg, tuning)
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
}

/// A front-end tunable, addressable by name in the same config file.
///
/// Deliberately a short list. `DSPTuning` holds a dozen filter constants and
/// most of them have no business being swept from a JSON file; these are the
/// ones the envelope-stage experiment needs, and every one of them defaults to
/// the shipped value, so a file that names none of them runs the shipped chain.
enum TuningParam: String, CaseIterable {
    /// 0 sliding max (shipped), 1 no dilation, 2 median, 3 decaying peak hold.
    case envelopeMode
    case envelopePeakSamples
    case envelopeDecayTauMs

    static var allNames: [String] { allCases.map(\.rawValue) }

    func set(_ t: inout DSPTuning, _ v: Double) throws {
        switch self {
        case .envelopeMode:
            guard let m = EnvelopeMode(rawValue: Int(v.rounded())) else {
                throw CLIError.usage("envelopeMode must be one of "
                    + EnvelopeMode.allCases.map { "\($0.rawValue) (\($0))" }.joined(separator: ", "))
            }
            t.envelopeMode = m
        case .envelopePeakSamples:
            let n = Int(v.rounded())
            guard n >= 1 else { throw CLIError.usage("envelopePeakSamples must be at least 1") }
            t.envelopePeakSamples = n
        case .envelopeDecayTauMs:
            guard v >= 0 else { throw CLIError.usage("envelopeDecayTauMs must not be negative") }
            t.envelopeDecayTauMs = v
        }
    }

    static func describe(_ t: DSPTuning) -> String? {
        guard t != .default else { return nil }
        return "  envelopeMode           \(t.envelopeMode) (\(t.envelopeMode.rawValue))\n"
             + "  envelopePeakSamples    \(t.envelopePeakSamples)\n"
             + "  envelopeDecayTauMs     \(String(format: "%g", t.envelopeDecayTauMs))\n"
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
        }
    }

    func display(_ c: DetectorConfig) -> String {
        guard let v = get(c) else { return "nil" }
        if isNanoseconds { return String(format: "%.1f ms", v / 1e6) }
        return String(format: "%g", v)
    }
}

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
        }
    }

    func display(_ c: DetectorConfig) -> String {
        guard let v = get(c) else { return "nil" }
        if isNanoseconds { return String(format: "%.1f ms", v / 1e6) }
        return String(format: "%g", v)
    }
}

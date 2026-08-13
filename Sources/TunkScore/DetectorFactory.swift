import Foundation
import TunkCore

enum DetectorBackend: String, CaseIterable {
    /// `TunkCore.TapDetector`, the one that ships.
    case real
    /// The harness's own placeholder, kept so the scoring logic can be self-tested
    /// independently of whatever the detector is doing this round.
    case stub
}

/// The single place the harness decides which `TapDetecting` implementation it
/// grades. Everything downstream — replay, matching, metrics, sweep, explain,
/// selftest — talks to the protocol only and does not care which class it got.
enum DetectorFactory {
    /// Set once from `--detector`. Single-threaded CLI; no locking needed.
    nonisolated(unsafe) static var backend: DetectorBackend = .real

    /// Printed in every report so nobody mistakes a stub run for a real one.
    static var backendName: String {
        switch backend {
        case .real: return "TunkCore.TapDetector"
        case .stub: return "stub (TunkScore/StubDetector.swift)"
        }
    }

    static var isStub: Bool { backend == .stub }

    static func make(config: DetectorConfig) -> TapDetecting {
        switch backend {
        case .real: return TapDetector(config: config)
        case .stub: return StubTapDetector(config: config)
        }
    }

    /// Parse `--detector <name>`, defaulting per command.
    static func select(_ raw: String?, default def: DetectorBackend) throws {
        guard let raw else { backend = def; return }
        guard let b = DetectorBackend(rawValue: raw) else {
            throw CLIError.usage("unknown --detector '\(raw)'. Known: "
                                 + DetectorBackend.allCases.map(\.rawValue).joined(separator: ", "))
        }
        backend = b
    }
}

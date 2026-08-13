// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tunk",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TunkCore", targets: ["TunkCore"]),
        .library(name: "TunkFormat", targets: ["TunkFormat"]),
        .library(name: "TunkIMU", targets: ["TunkIMU"]),
        .library(name: "TunkEmit", targets: ["TunkEmit"]),
        .executable(name: "tunk-capture", targets: ["TunkCapture"]),
        .executable(name: "tunk-score", targets: ["TunkScore"]),
        .executable(name: "tunk", targets: ["TunkApp"]),
    ],
    targets: [
        // Declarations for the private IOHIDEventSystemClient API plus a tiny
        // C bridge for the pieces Swift cannot express directly.
        .target(name: "CTunkHID"),

        // Detector: pure, deterministic, no IO, no clock. Shared by live and replay.
        .target(name: "TunkCore"),

        // Dataset read/write per FORMAT.md.
        .target(name: "TunkFormat", dependencies: ["TunkCore"]),

        // Accelerometer source + input-activity source.
        .target(name: "TunkIMU", dependencies: ["CTunkHID", "TunkCore"]),

        // Synthetic key emission via CGEventPost, with the stuck-modifier guard.
        .target(name: "TunkEmit", dependencies: ["TunkCore"]),

        .executableTarget(name: "TunkCapture", dependencies: ["TunkIMU", "TunkFormat", "TunkCore"]),
        .executableTarget(name: "TunkScore", dependencies: ["TunkFormat", "TunkCore"]),
        .executableTarget(name: "TunkApp", dependencies: ["TunkIMU", "TunkCore", "TunkFormat", "TunkEmit"]),

        .testTarget(name: "TunkCoreTests", dependencies: ["TunkCore", "TunkFormat", "TunkEmit"]),
    ]
)

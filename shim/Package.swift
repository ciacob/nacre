// swift-tools-version: 5.9
// Build:  swift build -c release  (from shim/)
// Test:   swift test              (from shim/)

import PackageDescription

let package = Package(
    name: "nacre",
    platforms: [
        .macOS(.v13)
    ],
    targets: [

        // ── Testable library (all logic, no Cocoa app lifecycle) ──────────
        // Both the executable and the test bundle import this.
        .target(
            name: "nacreLib",
            path: "Sources/nacreLib"
        ),

        // ── Main executable ───────────────────────────────────────────────
        // Contains only AppDelegate (@main) — all logic is in nacreLib.
        .executableTarget(
            name: "nacre",
            dependencies: ["nacreLib"],
            path: "Sources/nacre"
        ),

        // ── Unit-test bundle ──────────────────────────────────────────────
        .testTarget(
            name: "nacreTests",
            dependencies: ["nacreLib"],
            path: "Tests/nacreTests"
        )
    ]
)

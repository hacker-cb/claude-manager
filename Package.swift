// swift-tools-version:6.0
import PackageDescription

/// The whole app's logic lives in `ClaudeManagerCore`, a plain library target that
/// builds and tests headlessly with `swift test` (no Xcode, no window server). The
/// SwiftUI app shell is an Xcode target generated from `project.yml` (XcodeGen) and
/// depends on this package — see docs/DEVELOPMENT.md.
let package = Package(
    name: "ClaudeManager",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeManagerCore", targets: ["ClaudeManagerCore"])
    ],
    targets: [
        .target(
            name: "ClaudeManagerCore",
            // The usage-history store talks to the system SQLite via `import SQLite3`;
            // link libsqlite3 (always present on macOS — no external SwiftPM dependency).
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "ClaudeManagerCoreTests",
            dependencies: ["ClaudeManagerCore"]
        )
    ]
)

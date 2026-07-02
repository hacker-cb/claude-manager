// swift-tools-version:6.0
import PackageDescription

/// The whole app's logic lives in `ClaudeManagerCore`, a plain library target that
/// builds and tests headlessly with `swift test` (no Xcode, no window server). The
/// SwiftUI app shell is an Xcode target generated from `project.yml` (XcodeGen) and
/// depends on this package — see README.md § Build.
let package = Package(
    name: "ClaudeManager",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeManagerCore", targets: ["ClaudeManagerCore"])
    ],
    targets: [
        .target(
            name: "ClaudeManagerCore"
        ),
        .testTarget(
            name: "ClaudeManagerCoreTests",
            dependencies: ["ClaudeManagerCore"]
        )
    ]
)

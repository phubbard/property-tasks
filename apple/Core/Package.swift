// swift-tools-version: 6.0
// PropertyTasksCore: the model, projection, filter and sync client, ported from
// ../shared and verified against ../shared/fixtures. Foundation only, no
// third-party packages. `swift test` runs on the Mac without a simulator.
import PackageDescription

let package = Package(
    name: "PropertyTasksCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PropertyTasksCore", targets: ["PropertyTasksCore"]),
    ],
    targets: [
        .target(name: "PropertyTasksCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "PropertyTasksCoreTests", dependencies: ["PropertyTasksCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)

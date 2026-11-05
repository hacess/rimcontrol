// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RimControl",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure gesture state machine. No AppKit, no private frameworks, fully testable.
        .target(name: "RimCore"),
        // Menu bar app and all macOS integrations.
        .executableTarget(name: "RimControl", dependencies: ["RimCore"]),
        // Plain executable test runner: XCTest is not dependable with Command Line Tools alone.
        .executableTarget(name: "RimCoreChecks", dependencies: ["RimCore"]),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

// SwiftPM exposes the app logic to tests. The signed macOS app is still built
// with scripts/build-local.py or the Xcode project.
let package = Package(
    name: "WalkAndRoll",
    platforms: [.macOS("15.0")],
    targets: [
        .target(
            name: "WalkAndRoll",
            path: "WalkAndRoll",
            exclude: ["WalkAndRollApp.swift", "Assets.xcassets", "Info.plist"]
        ),
        .testTarget(name: "WalkAndRollTests", dependencies: ["WalkAndRoll"])
    ],
    swiftLanguageModes: [.v5]
)

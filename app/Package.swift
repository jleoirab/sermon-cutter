// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SermonCutter",
    platforms: [.macOS(.v15)],
    targets: [
        // Everything that doesn't draw: talking to the engine, the Sunday's
        // state, timecodes and file names.
        .target(
            name: "SermonCutterCore",
            path: "Sources/SermonCutterCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SermonCutter",
            dependencies: ["SermonCutterCore"],
            path: "Sources/SermonCutter",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SermonCutterCoreTests",
            dependencies: ["SermonCutterCore"],
            path: "Tests/SermonCutterCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SermonCutter",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that doesn't draw: talking to the engine, the Sunday's
        // state, timecodes and file names.
        .target(
            name: "SermonCutterCore",
            path: "Sources/SermonCutterCore"
        ),
        .executableTarget(
            name: "SermonCutter",
            dependencies: ["SermonCutterCore"],
            path: "Sources/SermonCutter"
        ),
        // For releasing: the release key, and latest.json for a new installer.
        .executableTarget(
            name: "SermonRelease",
            dependencies: ["SermonCutterCore"],
            path: "Sources/SermonRelease"
        ),
        .testTarget(
            name: "SermonCutterCoreTests",
            dependencies: ["SermonCutterCore"],
            path: "Tests/SermonCutterCoreTests"
        ),
    ]
)

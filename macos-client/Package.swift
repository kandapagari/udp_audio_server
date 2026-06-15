// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "UDPTTSMenuBar",
    platforms: [
        .macOS(.v14)  // MenuBarExtra + modern SwiftUI
    ],
    targets: [
        // Reusable networking/audio core shared by the app and the probe CLI.
        .target(
            name: "UDPTTSCore",
            path: "Sources/UDPTTSCore"
        ),
        // The menu-bar app.
        .executableTarget(
            name: "UDPTTSMenuBar",
            dependencies: ["UDPTTSCore"],
            path: "Sources/UDPTTSMenuBar"
        ),
        // Headless client: streams to a WAV file. Proves wire-compatibility
        // with the Python server without audio hardware or a GUI.
        .executableTarget(
            name: "udptts-probe",
            dependencies: ["UDPTTSCore"],
            path: "Sources/udptts-probe"
        ),
        .testTarget(
            name: "UDPTTSCoreTests",
            dependencies: ["UDPTTSCore"],
            path: "Tests/UDPTTSCoreTests"
        ),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shout",
    platforms: [.macOS("26.0")],
    targets: [
        // Prebuilt whisper.cpp (Metal-accelerated) from the official v1.9.1 release.
        // Fetched and checksum-verified by SwiftPM itself, so a fresh clone builds
        // with no bootstrap step. The checksum is enforced before the framework is
        // ever unzipped or executed: a moved tag or re-published asset fails closed
        // with "artifact ... has changed checksum". Bump both fields together.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-v1.9.1-xcframework.zip",
            checksum: "8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c"),

        // Engine layer: audio capture, transcription, rewrite, model management.
        .target(
            name: "ShoutCore",
            dependencies: ["whisper"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreML"),
                .linkedFramework("AVFoundation"),
                .linkedLibrary("c++"),
            ]
        ),

        // The menu-bar app.
        .executableTarget(
            name: "Shout",
            dependencies: ["ShoutCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Headless test harness: transcribe/rewrite from the command line.
        .executableTarget(
            name: "shout-cli",
            dependencies: ["ShoutCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Unit tests for the engine layer's pure logic.
        .testTarget(
            name: "ShoutCoreTests",
            dependencies: ["ShoutCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

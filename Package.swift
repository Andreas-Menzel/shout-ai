// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shout",
    platforms: [.macOS("26.0")],
    targets: [
        // Prebuilt whisper.cpp (Metal-accelerated) from the official v1.9.1 release.
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),

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

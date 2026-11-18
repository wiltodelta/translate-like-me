// swift-tools-version:6.2
import Foundation
import PackageDescription

let isMASBuild = ProcessInfo.processInfo.environment["TLM_EDITION"] == "mas"

var appDependencies: [Target.Dependency] = [
    "TranslateLikeMeBridgeKit",
    .product(name: "WhisperKit", package: "argmax-oss-swift"),
    .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
    .product(name: "MLX", package: "mlx-swift"),
    .product(name: "MLXNN", package: "mlx-swift"),
    .product(name: "MLXLLM", package: "mlx-swift-lm"),
    .product(name: "MLXVLM", package: "mlx-swift-lm"),
    .product(name: "MLXLMCommon", package: "mlx-swift-lm")
]
if !isMASBuild {
    appDependencies.insert(.product(name: "Sparkle", package: "Sparkle"), at: 0)
}

let localizedStringFlags = [
    "-emit-localized-strings",
    "-emit-localized-strings-path",
    Context.packageDirectory + "/.build/localized-strings"
]
var appSwiftSettings: [SwiftSetting] = [.unsafeFlags(localizedStringFlags)]
if isMASBuild {
    appSwiftSettings.append(.define("APP_STORE"))
}

let package = Package(
    name: "TranslateLikeMe",
    // Must match LSMinimumSystemVersion in Resources/Info.plist (build.sh checks).
    platforms: [.macOS("15.0")],
    dependencies: [
        // In-place updates from the appcast published with each release; build.sh
        // embeds and signs the framework for non-App-Store builds (docs/build-and-release.md).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
        // Local multilingual dictation needs an on-device ASR runtime; WhisperKit
        // runs Whisper through Core ML without a server or bundled Python.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.1"),
        // Native Qwen ASR and its Apple-silicon array runtime, without Python.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift", exact: "0.1.7"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        // Collections 1.7 supports Swift 6.2.4+ through its versioned manifest.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.7.5"),
        // The local translation engine: MLX runs the model on the GPU in this
        // process, with no server or Python. Its tokenizer is WhisperKit's.
        // Traits off: the default FoundationModels adapter needs the macOS 27 SDK.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3", traits: [])
    ],
    targets: [
        .target(
            name: "TranslateLikeMeBridgeKit",
            path: "Sources/TranslateLikeMeBridgeKit"
        ),
        .executableTarget(
            name: "TranslateLikeMe",
            dependencies: appDependencies,
            path: "Sources/TranslateLikeMe",
            exclude: isMASBuild ? ["Updater.swift"] : [],
            // The compiler lists every localizable string it type-checked, one
            // .stringsdata per source file, for scripts/sync-strings.py (build.sh).
            // Set here rather than through -Xswiftc so dependencies write none.
            swiftSettings: appSwiftSettings
        ),
        .executableTarget(
            name: "TranslateLikeMeBridge",
            dependencies: [
                "TranslateLikeMeBridgeKit",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/TranslateLikeMeBridge",
            swiftSettings: [.unsafeFlags(localizedStringFlags)]
        ),
        .testTarget(
            name: "TranslateLikeMeTests",
            dependencies: ["TranslateLikeMe", "TranslateLikeMeBridgeKit"],
            path: "Tests/TranslateLikeMeTests"
        )
    ]
)

// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "TranslateLikeMe",
    // Must match LSMinimumSystemVersion in Resources/Info.plist (build.sh checks).
    platforms: [.macOS("15.0")],
    dependencies: [
        // In-place updates from the appcast published with each release; build.sh
        // embeds and signs the framework (docs/build-and-release.md).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        // Local multilingual dictation needs an on-device ASR runtime; WhisperKit
        // runs Whisper through Core ML without a server or bundled Python.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.1"),
        // Native Qwen ASR and its Apple-silicon array runtime, without Python.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift", exact: "0.1.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        // Tokenizer dependency 1.7 requires Swift 6.4; CI runs Swift 6.3.3.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.6.0"),
        // The local translation engine: MLX runs the model on the GPU in this
        // process, with no server or Python. Its tokenizer is WhisperKit's.
        // Traits off: the default FoundationModels adapter needs the macOS 27 SDK.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3", traits: [])
    ],
    targets: [
        .executableTarget(
            name: "TranslateLikeMe",
            dependencies: [.product(name: "Sparkle", package: "Sparkle"),
                           .product(name: "WhisperKit", package: "argmax-oss-swift"),
                           .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                           .product(name: "MLX", package: "mlx-swift"),
                           .product(name: "MLXLLM", package: "mlx-swift-lm"),
                           .product(name: "MLXVLM", package: "mlx-swift-lm"),
                           .product(name: "MLXLMCommon", package: "mlx-swift-lm")],
            path: "Sources/TranslateLikeMe",
            // The compiler lists every localizable string it type-checked, one
            // .stringsdata per source file, for scripts/sync-strings.py (build.sh).
            // Set here rather than through -Xswiftc so dependencies write none.
            swiftSettings: [.unsafeFlags(["-emit-localized-strings", "-emit-localized-strings-path",
                                          Context.packageDirectory + "/.build/localized-strings"])]
        ),
        .testTarget(
            name: "TranslateLikeMeTests",
            dependencies: ["TranslateLikeMe"],
            path: "Tests/TranslateLikeMeTests"
        )
    ]
)

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
        // Optional fast multilingual ASR. Tools 6.2 lets us omit the unused
        // NeMo text-processing binary while keeping Swift 6 and macOS 15.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7", traits: [])
    ],
    targets: [
        .executableTarget(
            name: "TranslateLikeMe",
            dependencies: [.product(name: "Sparkle", package: "Sparkle"),
                           .product(name: "WhisperKit", package: "argmax-oss-swift"),
                           .product(name: "FluidAudio", package: "FluidAudio")],
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

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TranslateLikeMe",
    // Must match LSMinimumSystemVersion in Resources/Info.plist (build.sh checks).
    platforms: [.macOS("15.0")],
    dependencies: [
        // In-place updates from the appcast published with each release; build.sh
        // embeds and signs the framework (docs/build-and-release.md).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "TranslateLikeMe",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/TranslateLikeMe"
        ),
        .testTarget(
            name: "TranslateLikeMeTests",
            dependencies: ["TranslateLikeMe"],
            path: "Tests/TranslateLikeMeTests"
        )
    ]
)

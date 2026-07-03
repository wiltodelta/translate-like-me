// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TranslateLikeMe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TranslateLikeMe",
            path: "Sources/TranslateLikeMe"
        ),
        .testTarget(
            name: "TranslateLikeMeTests",
            dependencies: ["TranslateLikeMe"],
            path: "Tests/TranslateLikeMeTests"
        )
    ]
)

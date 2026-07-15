// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CombinedBinaryFixture",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CombinedBinaryFixture", targets: ["CombinedBinaryFixture"]),
    ],
    targets: [
        .binaryTarget(name: "StaticBadge", path: "Artifacts/StaticBadge.xcframework"),
        .binaryTarget(name: "DynamicBadge", path: "Artifacts/DynamicBadge.xcframework"),
        .target(
            name: "CombinedBinaryFixture",
            dependencies: ["StaticBadge", "DynamicBadge"]
        ),
    ]
)

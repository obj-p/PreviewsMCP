// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DynamicBinaryFixture",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "DynamicBinaryFixture", targets: ["DynamicBinaryFixture"]),
    ],
    targets: [
        .binaryTarget(name: "DynamicBadge", path: "Artifacts/DynamicBadge.xcframework"),
        .target(name: "DynamicBinaryFixture", dependencies: ["DynamicBadge"]),
    ]
)

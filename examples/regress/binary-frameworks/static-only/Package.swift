// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StaticBinaryFixture",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "StaticBinaryFixture", targets: ["StaticBinaryFixture"]),
    ],
    targets: [
        .binaryTarget(name: "StaticBadge", path: "Artifacts/StaticBadge.xcframework"),
        .target(name: "StaticBinaryFixture", dependencies: ["StaticBadge"]),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BadSliceFixture",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "BadSliceFixture", targets: ["BadSliceFixture"]),
    ],
    targets: [
        .binaryTarget(name: "BadSlice", path: "Artifacts/BadSlice.xcframework"),
        .target(name: "BadSliceFixture", dependencies: ["BadSlice"]),
    ]
)

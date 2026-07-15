// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PathFixture",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PathFixture", targets: ["PathFixture"]),
    ],
    targets: [
        .target(name: "PathFixture"),
    ]
)

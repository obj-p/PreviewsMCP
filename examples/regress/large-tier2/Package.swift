// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LargeTier2",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LargeTier2", targets: ["LargeTier2"]),
    ],
    targets: [
        .target(name: "LargeTier2"),
    ]
)

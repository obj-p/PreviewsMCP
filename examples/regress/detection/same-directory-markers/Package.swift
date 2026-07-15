// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HybridMarker",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HybridMarker", targets: ["HybridMarker"]),
    ],
    targets: [
        .target(name: "HybridMarker"),
    ]
)

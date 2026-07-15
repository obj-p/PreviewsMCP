// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NestedPackage",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NestedPackage", targets: ["NestedPackage"]),
    ],
    targets: [
        .target(name: "NestedPackage"),
    ]
)

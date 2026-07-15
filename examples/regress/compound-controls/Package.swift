// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompoundControls",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CompoundControls", targets: ["CompoundControls"]),
    ],
    targets: [
        .target(name: "CompoundControls"),
    ]
)

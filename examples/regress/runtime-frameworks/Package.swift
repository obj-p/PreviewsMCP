// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuntimeFrameworks",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RuntimeFrameworks", targets: ["RuntimeFrameworks"]),
    ],
    targets: [
        .target(name: "RuntimeFrameworks"),
    ]
)

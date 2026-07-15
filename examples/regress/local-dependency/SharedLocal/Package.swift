// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SharedLocal",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SharedLocal", targets: ["SharedLocal"]),
    ],
    targets: [
        .target(name: "SharedLocal"),
    ]
)

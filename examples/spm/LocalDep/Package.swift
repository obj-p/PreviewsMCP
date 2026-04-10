// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalDep",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LocalDep", targets: ["LocalDep"])
    ],
    targets: [
        .target(name: "LocalDep", path: "Sources/LocalDep")
    ]
)

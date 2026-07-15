// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalDependencyApp",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LocalDependencyApp", targets: ["LocalDependencyApp"]),
    ],
    dependencies: [
        .package(path: "../SharedLocal"),
    ],
    targets: [
        .target(
            name: "LocalDependencyApp",
            dependencies: [
                .product(name: "SharedLocal", package: "SharedLocal"),
            ]
        ),
    ]
)

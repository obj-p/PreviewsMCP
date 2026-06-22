// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mq",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../vz"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "mq",
            dependencies: [
                .product(name: "VZKit", package: "vz"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PreviewsMCP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "previews-mcp", targets: ["PreviewsCLI"]),
        .library(name: "PreviewsCore", targets: ["PreviewsCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.1"),
    ],
    targets: [
        .target(
            name: "SimulatorBridge"
        ),
        .target(
            name: "PreviewsCore",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "PreviewsMacOS",
            dependencies: ["PreviewsCore"]
        ),
        .target(
            name: "PreviewsIOS",
            dependencies: ["PreviewsCore", "SimulatorBridge"]
        ),
        .executableTarget(
            name: "PreviewsCLI",
            dependencies: [
                "PreviewsCore",
                "PreviewsMacOS",
                "PreviewsIOS",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "PreviewsCoreTests",
            dependencies: ["PreviewsCore"]
        ),
        .testTarget(
            name: "PreviewsIOSTests",
            dependencies: ["PreviewsIOS"]
        ),
    ]
)

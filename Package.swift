// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PreviewsMCP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "previewsmcp", targets: ["PreviewsCLI"]),
        .library(name: "PreviewsCore", targets: ["PreviewsCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.1"),
    ],
    targets: [
        .target(
            name: "SimulatorBridge",
            linkerSettings: [
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
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
            dependencies: ["PreviewsCore", "SimulatorBridge"],
            resources: [.copy("AppIcon.png")]
        ),
        .executableTarget(
            name: "PreviewsCLI",
            dependencies: [
                "PreviewsCore",
                "PreviewsMacOS",
                "PreviewsIOS",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            plugins: [.plugin(name: "GenerateVersion")]
        ),
        .executableTarget(
            name: "GenerateVersionTool"
        ),
        .plugin(
            name: "GenerateVersion",
            capability: .buildTool(),
            dependencies: ["GenerateVersionTool"]
        ),
        .testTarget(
            name: "PreviewsCoreTests",
            dependencies: ["PreviewsCore"]
        ),
        .testTarget(
            name: "PreviewsMacOSTests",
            dependencies: ["PreviewsMacOS"]
        ),
        .testTarget(
            name: "PreviewsIOSTests",
            dependencies: ["PreviewsIOS"]
        ),
        .testTarget(
            name: "CLIIntegrationTests",
            dependencies: []
        ),
        .testTarget(
            name: "MCPIntegrationTests",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
    ]
)

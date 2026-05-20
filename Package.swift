// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PreviewsMCP",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        .executable(name: "previewsmcp", targets: ["previewsmcp"]),
        .library(name: "PreviewsCore", targets: ["PreviewsCore"]),
        .library(name: "PreviewsSetupKit", targets: ["PreviewsSetupKit"]),
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
            name: "PreviewsJITLink",
            dependencies: ["PreviewsJITLinkCxx"]
        ),
        .target(
            // TODO: need to update to bundled version of LLVM in the future
            name: "PreviewsJITLinkCxx",
            cxxSettings: [
                .unsafeFlags(["-I/opt/homebrew/opt/llvm/include"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/opt/llvm/lib",
                    "-lLLVM",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/opt/homebrew/opt/llvm/lib",
                ])
            ]
        ),
        .testTarget(
            name: "PreviewsJITLinkTests",
            dependencies: ["PreviewsJITLink"]
        ),
        .target(
            name: "PreviewsSetupKit"
        ),
        .target(
            name: "PreviewsMacOS",
            dependencies: ["PreviewsCore"]
        ),
        .target(
            name: "PreviewsIOS",
            dependencies: ["PreviewsCore", "SimulatorBridge"],
            plugins: [.plugin(name: "EmbedHostAppSource")]
        ),
        .target(
            name: "PreviewsEngine",
            dependencies: ["PreviewsCore", "PreviewsIOS", "PreviewsMacOS"]
        ),
        .target(
            name: "PreviewsCLI",
            dependencies: [
                "PreviewsCore",
                "PreviewsMacOS",
                "PreviewsIOS",
                "PreviewsEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            plugins: [.plugin(name: "GenerateVersion")]
        ),
        .executableTarget(
            name: "previewsmcp",
            dependencies: ["PreviewsCLI"]
        ),
        .executableTarget(
            name: "GenerateVersionTool"
        ),
        .plugin(
            name: "GenerateVersion",
            capability: .buildTool(),
            dependencies: ["GenerateVersionTool"]
        ),
        .executableTarget(
            name: "EmbedHostAppSourceTool"
        ),
        .plugin(
            name: "EmbedHostAppSource",
            capability: .buildTool(),
            dependencies: ["EmbedHostAppSourceTool"]
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
            name: "PreviewsEngineTests",
            dependencies: ["PreviewsEngine"]
        ),
        .testTarget(
            name: "CLIIntegrationTests",
            dependencies: []
        ),
        .testTarget(
            name: "PreviewsCLITests",
            dependencies: [
                "PreviewsCLI",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "MCPIntegrationTests",
            dependencies: [
                "PreviewsCLI",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)

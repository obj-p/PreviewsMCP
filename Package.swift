// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let llvmBuild = "\(packageDir)/third_party/llvm-build"
let llvmSrcInclude = "\(packageDir)/third_party/llvm-project/llvm/include"
let orcRuntimeArchive = "\(packageDir)/third_party/llvm-build-rt/lib/darwin/liborc_rt_osx.a"

let jitEnabled =
    FileManager.default.fileExists(atPath: llvmBuild)
    && FileManager.default.fileExists(atPath: orcRuntimeArchive)

var targets: [Target] = [
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
        ],
        exclude: ["list_tools_snapshot.json"]
    ),
    .testTarget(
        name: "MCPIntegrationTests",
        dependencies: [
            "PreviewsCLI",
            .product(name: "MCP", package: "swift-sdk"),
        ]
    ),
]

if jitEnabled {
    targets += [
        .target(
            name: "PreviewsJITLink",
            dependencies: ["PreviewsJITLinkCxx"],
            plugins: [.plugin(name: "BundleOrcRuntime")]
        ),
        .target(
            // TODO: bundle libLLVM (U3); links the third_party build for now.
            name: "PreviewsJITLinkCxx",
            cxxSettings: [
                .unsafeFlags([
                    "-I\(llvmSrcInclude)",
                    "-I\(llvmBuild)/include",
                    "-fno-rtti",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(llvmBuild)/lib",
                    "-lLLVM",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "\(llvmBuild)/lib",
                ])
            ]
        ),
        .plugin(
            name: "BundleOrcRuntime",
            capability: .buildTool()
        ),
        .executableTarget(
            name: "PreviewAgent",
            cxxSettings: [
                .unsafeFlags([
                    "-I\(llvmSrcInclude)",
                    "-I\(llvmBuild)/include",
                    "-fno-rtti",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(llvmBuild)/lib",
                    "-lLLVM",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "\(llvmBuild)/lib",
                ])
            ]
        ),
        .testTarget(
            name: "PreviewsJITLinkTests",
            dependencies: ["PreviewsJITLink", "PreviewsCore"],
            exclude: ["Fixtures"]
        ),
    ]
}

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
    targets: targets,
    cxxLanguageStandard: .cxx17
)

// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let llvmBuild = "\(packageDir)/third_party/llvm-build"
let llvmSrcInclude = "\(packageDir)/third_party/llvm-project/llvm/include"
let orcRuntimeArchive = "\(packageDir)/third_party/llvm-build-rt/lib/darwin/liborc_rt_osx.a"

// JIT is mandatory on macOS: the dylib preview path has been retired, so the
// prebuilt LLVM artifacts must be present. Fail fast with a build-script hint
// rather than later at link time with an opaque missing-symbol error.
guard
    FileManager.default.fileExists(atPath: llvmBuild)
        && FileManager.default.fileExists(atPath: orcRuntimeArchive)
else {
    fatalError(
        "PreviewsMCP requires the prebuilt LLVM JIT artifacts. Run scripts/build-jit-llvm.sh first.")
}

// Composition-root wiring for the JIT structural-reload path.
let jitCLIDependencies: [Target.Dependency] = ["PreviewsJITLink"]

// iOS-simulator JIT is mandatory like macOS: the in-app ORC executor needs the
// cross-built iossim TargetProcess libs and the iossim orc runtime, staged into
// PreviewsIOS resources by the BundleIOSSimJIT plugin. The artifacts come from
// `scripts/build-jit-llvm-iossim.sh`; fail fast with a build-script hint if they
// are missing rather than later in the plugin's copy step.
let llvmBuildIOSSim = "\(packageDir)/third_party/llvm-build-iossim/lib/libLLVMOrcTargetProcess.a"
let orcRuntimeIOSSim = "\(packageDir)/third_party/llvm-build-rt/lib/darwin/liborc_rt_iossim.a"

guard
    FileManager.default.fileExists(atPath: llvmBuildIOSSim)
        && FileManager.default.fileExists(atPath: orcRuntimeIOSSim)
else {
    fatalError(
        "PreviewsMCP requires the prebuilt iossim JIT artifacts. Run scripts/build-jit-llvm-iossim.sh first."
    )
}

let iosJitPlugins: [Target.PluginUsage] = [.plugin(name: "BundleIOSSimJIT")]

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
        plugins: [.plugin(name: "EmbedHostAppSource")] + iosJitPlugins
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
        ] + jitCLIDependencies,
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

targets += [
    .plugin(
        name: "BundleIOSSimJIT",
        capability: .buildTool()
    ),
    .target(
        name: "PreviewsJITLink",
        dependencies: ["PreviewsJITLinkCxx", "PreviewsCore"],
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
        dependencies: ["PreviewsJITLink", "PreviewsCore", "PreviewAgent", "PreviewsIOS"],
        exclude: ["Fixtures"]
    ),
]

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

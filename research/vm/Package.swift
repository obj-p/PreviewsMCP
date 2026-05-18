// swift-tools-version: 6.0
//
// research/vm/ — Virtualization.framework wrapper CLI for the JIT spike.
//
// This package is intentionally NOT a target of the root Package.swift.
// See ../README.md for why; see jit-executor-research.md for what it's for.

import PackageDescription

let package = Package(
    name: "PreviewsVM",
    platforms: [.macOS(.v14)],
    products: [
        // The on-disk binary is named after the target — `previewsvm` —
        // for the usual shell ergonomics. The library is `PreviewsVMKit`
        // (rather than `PreviewsVM`) because APFS is case-insensitive by
        // default, so `previewsvm/` and `PreviewsVM/` would collapse into
        // the same directory; the `Kit` suffix keeps both as their own
        // distinct paths.
        .executable(name: "previewsvm", targets: ["previewsvm"]),
        .library(name: "PreviewsVMKit", targets: ["PreviewsVMKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "PreviewsVMObjC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
        .target(
            name: "PreviewsVMKit",
            dependencies: ["PreviewsVMObjC"]
        ),
        .executableTarget(
            name: "previewsvm",
            dependencies: [
                "PreviewsVMKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)

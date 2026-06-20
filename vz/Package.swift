// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vz",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "vz", targets: ["vz"]),
        .library(name: "VZKit", targets: ["VZKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "VZKitObjC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
        .target(
            name: "VZKit",
            dependencies: ["VZKitObjC"]
        ),
        .executableTarget(
            name: "vz",
            dependencies: [
                "VZKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)

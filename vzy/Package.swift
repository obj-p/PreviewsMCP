// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vzy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "vzy", targets: ["vzy"]),
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
            name: "vzy",
            dependencies: [
                "VZKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)

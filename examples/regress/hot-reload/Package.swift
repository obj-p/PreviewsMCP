// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HotReloadFixture",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HotReloadFixture", targets: ["HotReloadFixture"]),
    ],
    targets: [
        .target(
            name: "HotReloadFixture",
            path: "Sources/HotReload",
            resources: [.process("Resources")]
        ),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuntimeResources",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RuntimeResources", targets: ["RuntimeResources"]),
    ],
    targets: [
        .target(
            name: "RuntimeResources",
            resources: [.process("Resources")]
        ),
    ]
)

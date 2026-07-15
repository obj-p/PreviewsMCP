// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConfigCache",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ConfigCache", targets: ["ConfigCache"]),
    ],
    targets: [
        .target(
            name: "ConfigCache",
            path: "Nested/Sources/ConfigCache"
        ),
    ]
)

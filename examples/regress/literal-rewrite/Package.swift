// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiteralRewrite",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LiteralRewrite", targets: ["LiteralRewrite"]),
    ],
    targets: [
        .target(name: "LiteralRewrite"),
    ]
)

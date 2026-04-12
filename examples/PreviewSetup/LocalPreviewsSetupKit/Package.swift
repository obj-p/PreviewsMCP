// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PreviewsSetupKit",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        .library(name: "PreviewsSetupKit", targets: ["PreviewsSetupKit"])
    ],
    targets: [
        .target(name: "PreviewsSetupKit")
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlowPreviewSetupPackage",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [
        .package(path: "../../../../PreviewSetup/LocalPreviewsSetupKit"),
    ],
    targets: [
        .target(
            name: "SlowPreviewSetup",
            dependencies: [
                .product(name: "PreviewsSetupKit", package: "LocalPreviewsSetupKit"),
            ]
        ),
    ]
)

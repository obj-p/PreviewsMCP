// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PreviewSetup",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ToDoPreviewSetup", targets: ["ToDoPreviewSetup"])
    ],
    dependencies: [
        .package(path: "LocalPreviewsSetupKit")
    ],
    targets: [
        .target(
            name: "ToDoPreviewSetup",
            dependencies: [
                .product(name: "PreviewsSetupKit", package: "LocalPreviewsSetupKit")
            ]
        )
    ]
)

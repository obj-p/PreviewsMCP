// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ToDo",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ToDo", targets: ["ToDo"]),
        .library(name: "ToDoExtras", targets: ["ToDoExtras"]),
    ],
    dependencies: [
        .package(path: "LocalDep"),
        .package(url: "https://github.com/airbnb/lottie-spm.git", from: "4.4.0"),
        .package(name: "PreviewsMCP", path: "../.."),
    ],
    targets: [
        .target(
            name: "ToDoExtras",
            path: "Sources/ToDoExtras"
        ),
        .target(
            name: "ToDo",
            dependencies: [
                "ToDoExtras",
                .product(name: "LocalDep", package: "LocalDep"),
                .product(name: "Lottie", package: "lottie-spm"),
            ],
            path: "Sources/ToDo"
        ),
        .target(
            name: "ToDoPreviewSetup",
            dependencies: [
                .product(name: "PreviewsSetupKit", package: "PreviewsMCP"),
            ],
            path: "Sources/ToDoPreviewSetup"
        ),
    ]
)

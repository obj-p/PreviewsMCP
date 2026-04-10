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
        .package(path: "LocalDep")
    ],
    targets: [
        .target(
            name: "ToDoExtras",
            path: "Sources/ToDoExtras"
        ),
        .target(
            name: "ToDo",
            dependencies: ["ToDoExtras", .product(name: "LocalDep", package: "LocalDep")],
            path: "Sources/ToDo"
        ),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OuterMarker",
    products: [
        .library(name: "OuterMarker", targets: ["OuterMarker"]),
    ],
    targets: [
        .target(name: "OuterMarker"),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeviceFlag",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DeviceFlag", targets: ["DeviceFlag"]),
    ],
    targets: [
        .target(name: "DeviceFlag"),
    ]
)

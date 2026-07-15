// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlowSetupApp",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SetupFaultApp", targets: ["SetupFaultApp"]),
    ],
    targets: [
        .target(name: "SetupFaultApp"),
    ]
)

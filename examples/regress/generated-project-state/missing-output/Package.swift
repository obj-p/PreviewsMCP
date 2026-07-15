// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MissingOutputFallback",
    targets: [
        .target(name: "MissingOutputFallback", path: "FallbackSources"),
    ]
)

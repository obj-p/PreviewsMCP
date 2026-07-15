// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LifecycleFaults",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SessionReplacement", targets: ["SessionReplacement"]),
        .library(name: "MissingSymbol", targets: ["MissingSymbol"]),
        .library(name: "SlowRender", targets: ["SlowRender"]),
        .library(name: "AgentCrash", targets: ["AgentCrash"]),
        .library(name: "ConcurrentA", targets: ["ConcurrentA"]),
        .library(name: "ConcurrentB", targets: ["ConcurrentB"]),
    ],
    targets: [
        .target(name: "SessionReplacement"),
        .target(name: "MissingSymbol"),
        .target(name: "SlowRender"),
        .target(name: "AgentCrash"),
        .target(name: "ConcurrentA"),
        .target(name: "ConcurrentB"),
    ]
)

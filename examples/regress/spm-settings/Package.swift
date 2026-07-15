// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SettingsFixture",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SettingsFixture", targets: ["SettingsFixture"]),
        .library(name: "CompilerSettings", targets: ["CompilerSettings"]),
        .library(name: "GeneratedPlugin", targets: ["GeneratedPlugin"]),
        .library(name: "MembershipAndC", targets: ["MembershipAndC"]),
    ],
    targets: [
        .target(
            name: "FixtureC",
            publicHeadersPath: "include",
            cSettings: [
                .define("FIXTURE_C_BUILD", to: "1"),
            ]
        ),
        .executableTarget(name: "FixtureCodegen"),
        .plugin(
            name: "GenerateFixtureStamp",
            capability: .buildTool(),
            dependencies: ["FixtureCodegen"]
        ),
        .target(
            name: "SettingsFixture",
            dependencies: ["FixtureC"],
            path: "Sources/SettingsFixture",
            exclude: ["Excluded"],
            sources: [
                "SettingsPreview.swift",
                "UIKitIsolation.swift",
            ],
            resources: [.process("Resources")],
            swiftSettings: [
                .define(
                    "SETTINGS_FIXTURE",
                    .when(platforms: [.iOS, .macOS], configuration: .debug)
                ),
                .enableUpcomingFeature("ExistentialAny"),
                .unsafeFlags(
                    ["-strict-concurrency=targeted"],
                    .when(configuration: .debug)
                ),
            ],
            plugins: [.plugin(name: "GenerateFixtureStamp")]
        ),
        .target(
            name: "CompilerSettings",
            swiftSettings: [
                .define(
                    "COMPILER_SETTINGS_PRESENT",
                    .when(platforms: [.iOS, .macOS], configuration: .debug)
                ),
                .enableUpcomingFeature("ExistentialAny"),
                .unsafeFlags(
                    ["-strict-concurrency=targeted"],
                    .when(configuration: .debug)
                ),
            ]
        ),
        .target(
            name: "GeneratedPlugin",
            plugins: [.plugin(name: "GenerateFixtureStamp")]
        ),
        .target(
            name: "MembershipAndC",
            dependencies: ["FixtureC"],
            exclude: ["Excluded"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)

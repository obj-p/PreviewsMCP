// swift-tools-version: 6.0
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "MacroFixture",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MacroClient", targets: ["MacroClient"]),
        .library(name: "ToolchainMacroClient", targets: ["ToolchainMacroClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.1"..<"603.0.0"),
    ],
    targets: [
        .macro(
            name: "FixtureMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(name: "FixtureMacros", dependencies: ["FixtureMacrosPlugin"]),
        .target(name: "MacroClient", dependencies: ["FixtureMacros"]),
        .target(name: "ToolchainMacroClient"),
    ]
)

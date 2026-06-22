import ArgumentParser
import CryptoKit
import Darwin
import Foundation

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Compile, codesign, and run a Swift script against VZKit."
    )

    @Argument(parsing: .captureForPassthrough, help: "Script path, then args passed to it.")
    var items: [String] = []

    struct RunError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    func run() throws {
        guard let scriptPath = items.first else {
            throw ValidationError("usage: vz run <script.swift> [args…]")
        }
        let scriptArgs = Array(items.dropFirst())

        let scriptURL = URL(filePath: scriptPath)
        let source = try String(contentsOf: scriptURL, encoding: .utf8)

        let packageRoot = Self.packageRoot
        let entitlements = packageRoot.appending(path: "Resources/vz.entitlements")

        let digest = SHA256.hash(data: Data((source + packageRoot.path).utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".cache/vz-run/\(hash)")

        try Self.synthesizePackage(at: cacheDir, source: source, packageRoot: packageRoot)
        try Self.sh("/usr/bin/swift", ["build", "-c", "release", "--package-path", cacheDir.path])
        let binDir = try Self.capture(
            "/usr/bin/swift",
            ["build", "-c", "release", "--package-path", cacheDir.path, "--show-bin-path"])
        let binary = URL(filePath: binDir).appending(path: "vzscript")
        try Self.sh(
            "/usr/bin/codesign",
            ["--force", "--sign", "-", "--entitlements", entitlements.path, binary.path])

        let process = Process()
        process.executableURL = binary
        process.arguments = scriptArgs
        try process.run()
        process.waitUntilExit()
        Darwin.exit(process.terminationStatus)
    }

    static var packageRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func synthesizePackage(at dir: URL, source: String, packageRoot: URL) throws {
        let sourcesDir = dir.appending(path: "Sources/vzscript")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        let manifest = """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "vzscript",
                platforms: [.macOS(.v14)],
                dependencies: [.package(path: \"\(packageRoot.path)\")],
                targets: [
                    .executableTarget(
                        name: "vzscript",
                        dependencies: [.product(name: "VZKit", package: "vz")]
                    )
                ]
            )
            """
        try manifest.write(to: dir.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try source.write(
            to: sourcesDir.appending(path: "main.swift"), atomically: true, encoding: .utf8)
    }

    static func sh(_ path: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RunError(message: "\(path) \(args.joined(separator: " ")) exited \(process.terminationStatus)")
        }
    }

    static func capture(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

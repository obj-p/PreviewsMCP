import Foundation

enum FixtureSupport {
    enum FixtureError: Error, CustomStringConvertible {
        case compileFailed(source: String, status: Int32, output: String)

        var description: String {
            switch self {
            case let .compileFailed(source, status, output):
                return "compiling \(source) failed (status \(status)):\n\(output)"
            }
        }
    }

    private static var fixturesDirectory: URL {
        if let root = ProcessInfo.processInfo.environment["PREVIEWSMCP_REPO_ROOT"] {
            return URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(
                    "previewsmcp/Tests/PreviewsJITLinkTests/Fixtures", isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    static func compile(_ source: String, extraFlags: [String] = []) throws -> URL {
        let input = fixturesDirectory.appendingPathComponent(source)
        let output = outputURL(for: source)

        if isUpToDate(output: output, input: input) {
            return output
        }

        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let arguments = compileArguments(input: input, output: output) + extraFlags
        let result = try run("/usr/bin/xcrun", arguments)
        guard result.status == 0 else {
            throw FixtureError.compileFailed(
                source: source,
                status: result.status,
                output: result.output
            )
        }
        return output
    }

    private static func compileArguments(input: URL, output: URL) -> [String] {
        switch input.pathExtension {
        case "swift":
            return [
                "swiftc", "-c", "-parse-as-library",
                "-module-name", "Fixtures",
                input.path, "-o", output.path,
            ]
        default:
            return ["clang", "-c", input.path, "-o", output.path]
        }
    }

    private static func outputURL(for source: String) -> URL {
        let stem = (source as NSString).deletingPathExtension
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewsJITLinkFixtures", isDirectory: true)
            .appendingPathComponent("\(stem).o")
    }

    private static func isUpToDate(output: URL, input: URL) -> Bool {
        let fm = FileManager.default
        guard
            let outDate = try? fm.attributesOfItem(atPath: output.path)[.modificationDate] as? Date,
            let inDate = try? fm.attributesOfItem(atPath: input.path)[.modificationDate] as? Date
        else {
            return false
        }
        return outDate >= inDate
    }

    private static func run(_ executable: String, _ arguments: [String]) throws
        -> (status: Int32, output: String)
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

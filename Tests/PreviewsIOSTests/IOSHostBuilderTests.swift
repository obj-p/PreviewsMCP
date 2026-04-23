import Foundation
import Testing

@testable import PreviewsIOS

@Suite("IOSHostBuilder", .serialized)
struct IOSHostBuilderTests {

    @Test("Build iOS host app produces valid .app bundle")
    func buildHostApp() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-host-test-\(UUID().uuidString)")
        let builder = try await IOSHostBuilder(workDir: workDir)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let appPath = try await builder.ensureHostApp()

        // Verify .app directory exists
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: appPath.path, isDirectory: &isDir))
        #expect(isDir.boolValue)

        // Verify binary exists inside .app
        let binaryPath = appPath.appendingPathComponent("PreviewsMCPHost")
        #expect(FileManager.default.fileExists(atPath: binaryPath.path))

        // Verify Info.plist exists
        let plistPath = appPath.appendingPathComponent("Info.plist")
        #expect(FileManager.default.fileExists(atPath: plistPath.path))

        // Verify binary is compiled for iOS simulator (arm64)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        process.arguments = [binaryPath.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(output.contains("arm64"))

        // Guard against silent mis-escaping in the embedded `"""…"""` host-app
        // source: the error screen's title should survive round-tripping into
        // the compiled binary as a literal string. If someone double-escapes
        // or drops a character, the byte search misses and the test fails
        // before a user hits a broken error screen in the simulator.
        let binaryData = try Data(contentsOf: binaryPath)
        let title = Data("Preview host error".utf8)
        #expect(
            binaryData.range(of: title) != nil,
            "compiled host binary should embed the error-screen title verbatim"
        )

        print("Built iOS host app at: \(appPath.path)")
        print("Binary info: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    @Test("ensureHostApp returns cached path on second call")
    func caching() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-host-test-\(UUID().uuidString)")
        let builder = try await IOSHostBuilder(workDir: workDir)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let first = try await builder.ensureHostApp()
        let second = try await builder.ensureHostApp()
        #expect(first.path == second.path)
    }
}

import Foundation
@testable import PreviewsIOS
import Testing

@Suite("IOSAgentBuilder", .serialized)
struct IOSAgentBuilderTests {
    @Test("Build iOS agent app produces valid .app bundle")
    func buildAgentApp() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-host-test-\(UUID().uuidString)")
        let builder = try await IOSAgentBuilder(workDir: workDir)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let appPath = try await builder.ensureAgentApp()

        // Verify .app directory exists
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: appPath.path, isDirectory: &isDir))
        #expect(isDir.boolValue)

        // Verify binary exists inside .app
        let binaryPath = appPath.appendingPathComponent("PreviewsMCPAgent")
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

        // Guard against silent mis-escaping in the embedded `"""…"""` agent-app
        // source: a known literal string should survive round-tripping into the
        // compiled binary verbatim. If someone double-escapes or drops a
        // character, the byte search misses.
        let binaryData = try Data(contentsOf: binaryPath)
        let marker = Data("PreviewAgent: Failed to create socket".utf8)
        #expect(
            binaryData.range(of: marker) != nil,
            "compiled agent binary should embed the agent-app log string verbatim"
        )

        print("Built iOS agent app at: \(appPath.path)")
        print("Binary info: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    @Test("ensureAgentApp returns cached path on second call")
    func caching() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-host-test-\(UUID().uuidString)")
        let builder = try await IOSAgentBuilder(workDir: workDir)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let first = try await builder.ensureAgentApp()
        let second = try await builder.ensureAgentApp()
        #expect(first.path == second.path)
    }
}

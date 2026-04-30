import Foundation
import MCP
import Testing

@testable import PreviewsCLI

/// Coverage for `preview_build_info` and the staleness primitive it
/// surfaces. The integration-test skill aborts when `stale: true`, so the
/// load-bearing OS behavior — that `stat` on the binary path advances after
/// `swift build` (atomic-rename or in-place rewrite) while the running
/// process keeps its own start time — is exactly what these tests lock in.
/// See issue #147.
@Suite("preview_build_info", .serialized)
struct BuildInfoTests {

    /// Fresh server, untouched binary. Round-trip the structured payload
    /// and confirm shape: every field present, `stale: false`, mtime
    /// strictly less than (or equal to) processStartTime.
    @Test("returns structured payload with stale=false on a fresh server")
    func freshServerNotStale() async throws {
        let server = try await MCPTestServer.start()
        defer { server.stop() }

        let result = try await server.callToolResult(name: "preview_build_info")
        let info = try MCPTestServer.decodeStructured(
            DaemonProtocol.BuildInfoResult.self, from: result
        )

        #expect(info.binaryPath.hasSuffix("/previewsmcp"), "binaryPath = \(info.binaryPath)")
        #expect(!info.binaryMtime.isEmpty)
        #expect(!info.processStartTime.isEmpty)
        #expect(info.stale == false, "fresh server should not be stale: \(info)")

        // mtime <= processStartTime is the freshness invariant. We don't
        // assert strict <, because the build-and-spawn sequence under
        // test-suite parallelism can land within the same wall-clock
        // millisecond.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let mtime = try #require(formatter.date(from: info.binaryMtime))
        let started = try #require(formatter.date(from: info.processStartTime))
        #expect(mtime <= started, "mtime \(mtime) should be <= processStart \(started)")
    }

    /// Force the on-disk binary's mtime to a strictly-future timestamp via
    /// `utimensat` and re-call. The handler must report `stale: true` and
    /// `binaryMtime > <pre-mutation mtime>` strictly. This is the OS
    /// behavior the integration-test skill's abort path depends on — if a
    /// future linker/sandbox change ever decoupled the path-stat from the
    /// post-rebuild file, this test surfaces it instead of the tool
    /// silently lying.
    @Test("reports stale=true after binary mtime is advanced post-spawn")
    func mtimeAdvanceMakesServerStale() async throws {
        let server = try await MCPTestServer.start()
        defer { server.stop() }

        // Capture pre-mutation values from a fresh call.
        let before = try MCPTestServer.decodeStructured(
            DaemonProtocol.BuildInfoResult.self,
            from: try await server.callToolResult(name: "preview_build_info")
        )
        #expect(before.stale == false)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let preMtime = try #require(formatter.date(from: before.binaryMtime))
        let processStart = try #require(formatter.date(from: before.processStartTime))

        // Set the binary's mtime to a strictly-future timestamp. Future
        // means "after processStartTime" — that's the staleness primitive.
        let futureDate = processStart.addingTimeInterval(60)
        try setMtime(at: before.binaryPath, to: futureDate)

        let after = try MCPTestServer.decodeStructured(
            DaemonProtocol.BuildInfoResult.self,
            from: try await server.callToolResult(name: "preview_build_info")
        )

        let postMtime = try #require(formatter.date(from: after.binaryMtime))
        #expect(after.stale == true, "after mtime advance should be stale: \(after)")
        #expect(postMtime > preMtime, "mtime should advance: \(preMtime) -> \(postMtime)")
        #expect(
            postMtime > processStart,
            "post mtime \(postMtime) should exceed processStart \(processStart)"
        )

        // Restore the original mtime so subsequent test runs (and the
        // user's local `swift build` cache invalidation) aren't perturbed.
        // Best-effort: errors here are benign — the next `swift build`
        // will reset the mtime regardless.
        try? setMtime(at: before.binaryPath, to: preMtime)
    }

    /// Wrapper around `utimensat(2)` that sets both atime and mtime to
    /// `date`. We use the libc primitive (rather than `touch -t`) for
    /// sub-second precision and to keep the test free of shell timing
    /// quirks across macOS versions.
    private func setMtime(at path: String, to date: Date) throws {
        let seconds = time_t(date.timeIntervalSince1970)
        let nanoseconds = Int(
            (date.timeIntervalSince1970 - TimeInterval(seconds)) * 1_000_000_000
        )
        var times = (
            timespec(tv_sec: seconds, tv_nsec: nanoseconds),  // atime
            timespec(tv_sec: seconds, tv_nsec: nanoseconds)  // mtime
        )
        let result = withUnsafePointer(to: &times) { ptr -> Int32 in
            ptr.withMemoryRebound(to: timespec.self, capacity: 2) { ts in
                utimensat(AT_FDCWD, path, ts, 0)
            }
        }
        if result != 0 {
            let err = String(cString: strerror(errno))
            throw BuildInfoTestError.utimensatFailed(path: path, message: err)
        }
    }

    private enum BuildInfoTestError: Error, CustomStringConvertible {
        case utimensatFailed(path: String, message: String)

        var description: String {
            switch self {
            case .utimensatFailed(let path, let message):
                return "utimensat(\(path)) failed: \(message)"
            }
        }
    }
}

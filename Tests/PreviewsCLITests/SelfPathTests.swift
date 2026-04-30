import Foundation
import Testing

@testable import PreviewsCLI

/// Unit tests for `resolveRunningBinaryPath`. The fix for issue #100 swapped
/// the daemon-spawn self-path lookup from `argv[0]` to `_NSGetExecutablePath`.
/// The chdir test below is the load-bearing one — it pins the property argv[0]
/// lacked (CWD-independence). The whole suite is `.serialized` because the
/// chdir test mutates process-global state.
@Suite("SelfPath", .serialized)
struct SelfPathTests {

    @Test("returns an absolute, executable path")
    func returnsAbsoluteExecutable() throws {
        let path = try #require(resolveRunningBinaryPath())
        #expect(path.hasPrefix("/"), "expected absolute path, got \(path)")
        #expect(
            FileManager.default.isExecutableFile(atPath: path),
            "expected executable at \(path)")
    }

    @Test("returns the same value across calls")
    func deterministic() throws {
        let first = try #require(resolveRunningBinaryPath())
        let second = try #require(resolveRunningBinaryPath())
        #expect(first == second)
    }

    @Test("invariant under chdir — the property argv[0] lacks")
    func invariantUnderChdir() throws {
        let original = FileManager.default.currentDirectoryPath
        defer { _ = FileManager.default.changeCurrentDirectoryPath(original) }

        let before = try #require(resolveRunningBinaryPath())
        #expect(FileManager.default.changeCurrentDirectoryPath("/tmp"))
        let after = try #require(resolveRunningBinaryPath())
        #expect(before == after)
    }
}

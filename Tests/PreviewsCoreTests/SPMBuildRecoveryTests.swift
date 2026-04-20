import Foundation
import Testing

@testable import PreviewsCore

@Suite("SPMBuildRecovery")
struct SPMBuildRecoveryTests {

    @Test("parseStaleTripleDirectory extracts <triple> dir from real SPM error")
    func parsesRealError() {
        let stderr = """
            error: command /pkg/.build/arm64-apple-ios-simulator/debug/swift-version--FE76C4972A19952.txt not registered
            error: failed to write auxiliary file: command /pkg/.build/arm64-apple-ios-simulator/debug/swift-version--FE76C4972A19952.txt not registered
            """

        let url = SPMBuildRecovery.parseStaleTripleDirectory(stderr: stderr)
        #expect(url?.path == "/pkg/.build/arm64-apple-ios-simulator")
    }

    @Test("parseStaleTripleDirectory handles macOS triple")
    func parsesMacosTriple() {
        let stderr =
            "error: command /a/b/.build/arm64-apple-macosx/debug/swift-version--XYZ.txt not registered\n"
        let url = SPMBuildRecovery.parseStaleTripleDirectory(stderr: stderr)
        #expect(url?.path == "/a/b/.build/arm64-apple-macosx")
    }

    @Test("parseStaleTripleDirectory returns nil when no error pattern present")
    func returnsNilForUnrelatedStderr() {
        let stderr = "warning: deprecation\nerror: something else happened\n"
        #expect(SPMBuildRecovery.parseStaleTripleDirectory(stderr: stderr) == nil)
    }

    @Test("parseStaleTripleDirectory returns nil when path doesn't contain .build")
    func returnsNilForPathWithoutBuildMarker() {
        let stderr = "error: command /tmp/foo.txt not registered\n"
        #expect(SPMBuildRecovery.parseStaleTripleDirectory(stderr: stderr) == nil)
    }

    @Test("cleanStaleArtifacts removes both <triple>/ and sibling build.db, leaves peer dirs")
    func cleanStaleArtifactsRemovesBoth() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let buildDir = tmp.appendingPathComponent(".build")
        let tripleDir = buildDir.appendingPathComponent("arm64-apple-ios-simulator")
        let configDir = tripleDir.appendingPathComponent("debug")
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Stale state: a file inside <triple>/<config>/ and the shared build.db.
        let staleFile = configDir.appendingPathComponent("swift-version--XYZ.txt")
        try Data("v1\n".utf8).write(to: staleFile)
        let buildDB = buildDir.appendingPathComponent("build.db")
        try Data("db\n".utf8).write(to: buildDB)
        // A peer triple dir that must NOT be touched.
        let peerTripleDir = buildDir.appendingPathComponent("arm64-apple-macosx")
        try fm.createDirectory(at: peerTripleDir, withIntermediateDirectories: true)
        let peerFile = peerTripleDir.appendingPathComponent("keep-me.txt")
        try Data("keep\n".utf8).write(to: peerFile)

        SPMBuildRecovery.cleanStaleArtifacts(tripleDir: tripleDir)

        #expect(!fm.fileExists(atPath: tripleDir.path), "stale triple dir should be removed")
        #expect(!fm.fileExists(atPath: buildDB.path), "shared build.db should be removed")
        #expect(fm.fileExists(atPath: buildDir.path), ".build/ itself should remain")
        #expect(fm.fileExists(atPath: peerFile.path), "peer triple dir must not be touched")
    }

    @Test("cleanStaleArtifacts is a no-op when paths don't exist")
    func cleanStaleArtifactsToleratesMissing() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let tripleDir = tmp.appendingPathComponent(".build/arm64-apple-ios-simulator")
        // Don't create anything — just verify no throw and no crash.
        SPMBuildRecovery.cleanStaleArtifacts(tripleDir: tripleDir)
        #expect(!fm.fileExists(atPath: tripleDir.path))
    }
}

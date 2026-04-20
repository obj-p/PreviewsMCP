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
}

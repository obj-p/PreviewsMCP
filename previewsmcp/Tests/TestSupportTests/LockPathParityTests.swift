import Foundation
import PreviewsTestSupport
import Testing

struct LockPathParityTests {
    @Test func simlockScriptLocksTheSamePathAsSimulatorTestLock() throws {
        let srcdir = try #require(ProcessInfo.processInfo.environment["TEST_SRCDIR"])
        let script = try String(
            contentsOfFile: "\(srcdir)/_main/tools/simlock", encoding: .utf8
        )
        let match = try #require(
            script.firstMatch(of: /LOCK_PATH = os\.path\.expanduser\("~\/(.+)"\)/)
        )
        let scriptPath =
            (NSHomeDirectory() as NSString).appendingPathComponent(String(match.1))
        #expect(scriptPath == SimulatorTestLock.lockPath)
    }
}

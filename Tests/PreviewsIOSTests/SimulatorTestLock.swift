import Foundation

/// Cross-suite serialization for tests that boot/use iOS simulators.
///
/// Swift Testing runs `@Suite`s in parallel by default, and `@Suite(.serialized)`
/// only orders tests within a single suite. That's insufficient here:
/// `SimulatorManagerTests` (which boots its own simulator) and
/// `IOSPreviewSessionTests` (end-to-end boot+screenshot) both select from
/// the same `xcrun simctl list` pool with logic that usually converges on
/// the same device (first `.shutdown`, first available). Without a
/// cross-suite lock, they boot the same simulator concurrently — one
/// shuts it down while the other is screenshotting, and at least one
/// test hangs waiting for a display subsystem that's being torn down.
///
/// Observed in PR #141 CI run 72576100973: two iOS suites started at the
/// exact same ms (Test Suite 'IOSPreviewSession' + Test Suite
/// 'SimulatorManager' both at 19:45:41.987), tests failed with
/// `simctl io screenshot hung (exceeded 60s)` when the simulator was
/// mid-shutdown from the other suite.
///
/// Pattern mirrors `Tests/MCPIntegrationTests/DaemonTestLock.swift` —
/// blocking `flock(LOCK_EX)` on a detached thread to avoid starving
/// Swift's cooperative pool. Any iOS simulator-touching test wraps its
/// body in `SimulatorTestLock.run { ... }` to serialize.
enum SimulatorTestLock {

    private static var lockPath: String {
        // /tmp is writable on all macOS runners and not namespaced per
        // test target, so it serializes across Swift Testing targets too.
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("previewsmcp-simulator-test.lock")
    }

    static func run<T: Sendable>(body: @Sendable () async throws -> T) async throws -> T {
        let path = lockPath
        let fd = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Int32, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let dir = (path as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true)
                let fd = open(path, O_CREAT | O_RDWR, 0o644)
                guard fd >= 0 else {
                    cont.resume(
                        throwing: NSError(
                            domain: NSPOSIXErrorDomain, code: Int(errno),
                            userInfo: [
                                NSLocalizedDescriptionKey: "open(\(path)) failed"
                            ]))
                    return
                }
                // Blocking flock on a Dispatch thread — does NOT consume
                // a Swift cooperative thread, so other suites' async work
                // can proceed while this one waits.
                if flock(fd, LOCK_EX) != 0 {
                    close(fd)
                    cont.resume(
                        throwing: NSError(
                            domain: NSPOSIXErrorDomain, code: Int(errno),
                            userInfo: [NSLocalizedDescriptionKey: "flock failed"]))
                    return
                }
                cont.resume(returning: fd)
            }
        }

        let result: Swift.Result<T, Error>
        do {
            result = .success(try await body())
        } catch {
            result = .failure(error)
        }

        _ = flock(fd, LOCK_UN)
        close(fd)
        return try result.get()
    }
}

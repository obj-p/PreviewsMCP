import Foundation
import PreviewsCore
import Testing

@testable import PreviewsMacOS

@MainActor
@Suite("PreviewHost")
struct PreviewHostTests {

    /// Regression guard for the iOS `run` hot-reload bug.
    ///
    /// `FileWatcher`'s timer closure captures self weakly, so a watcher goes
    /// silent as soon as the binding that owns it falls out of scope. The
    /// iOS `launchIOSPreview` path creates a watcher inside a function that
    /// returns, so without an external retain the watcher deinits and hot
    /// reload silently stops firing. `PreviewHost.retainFileWatcher` is the
    /// hand-off that keeps it alive — if that mechanism breaks, this test
    /// should go red.
    @Test("retainFileWatcher keeps a watcher alive past the creating scope")
    func retainFileWatcherKeepsWatcherAlive() async throws {
        let host = PreviewHost()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-host-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("watched.swift")
        try "initial".write(to: file, atomically: true, encoding: .utf8)

        let fired = Mutex(false)

        // Inner scope intentionally releases its local `watcher` binding
        // before we touch the file. Without `retainFileWatcher` the watcher
        // would deinit here and the callback below would never fire.
        do {
            let watcher = try FileWatcher(path: file.path, interval: 0.1) {
                fired.withLock { $0 = true }
            }
            host.retainFileWatcher(watcher)
        }

        // Give the inner scope's release a chance to actually run.
        try await Task.sleep(for: .milliseconds(200))

        // Modify the file — the retained watcher should see it.
        try "modified".write(to: file, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(500))

        #expect(
            fired.withLock { $0 },
            "retainFileWatcher should keep the watcher alive past the creating scope"
        )
    }
}

/// Minimal thread-safe box for shuttling a `Bool` between the watcher's
/// callback queue and the test's main actor.
final class Mutex<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) { self.value = value }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

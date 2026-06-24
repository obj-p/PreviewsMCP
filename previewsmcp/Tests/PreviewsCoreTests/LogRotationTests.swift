import Foundation
@testable import PreviewsCore
import Testing

/// Each test opens its own private fd to a temp `serve.log` and passes that fd
/// to `rotateIfNeeded`, so the `dup2` inside rotation only retargets the test's
/// fd — never the process-global fd 2 that `LogTests.captureStderr` must
/// serialize around. That keeps this suite parallel-safe.
@Suite("LogRotation")
struct LogRotationTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logrot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    @Test("under threshold is a no-op")
    func underThreshold() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("serve.log")
        try Data("small".utf8).write(to: log)
        let fd = open(log.path, O_WRONLY)
        defer { close(fd) }

        let rotated = LogRotation.rotateIfNeeded(
            logURL: log, fd: fd, maxBytes: 1024, keep: 3
        )

        #expect(rotated == false)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("serve.log.1").path))
    }

    @Test("rotates and reopens over threshold")
    func rotateReopen() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("serve.log")
        let dot1 = dir.appendingPathComponent("serve.log.1")
        let old = String(repeating: "x", count: 2048)
        try Data(old.utf8).write(to: log)
        let fd = open(log.path, O_WRONLY)
        defer { close(fd) }

        let rotated = LogRotation.rotateIfNeeded(
            logURL: log, fd: fd, maxBytes: 1024, keep: 3
        )

        #expect(rotated)
        #expect(read(dot1) == old)
        #expect(read(log) == "")

        let msg = "new line\n"
        let n = msg.withCString { write(fd, $0, strlen($0)) }
        #expect(n == msg.utf8.count)
        #expect(read(log) == msg)
        #expect(read(dot1) == old)
    }

    @Test("ring caps and drops the oldest")
    func ringCap() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        func f(_ name: String) -> URL {
            dir.appendingPathComponent(name)
        }
        let log = f("serve.log")
        try Data("C".utf8).write(to: f("serve.log.3"))
        try Data("B".utf8).write(to: f("serve.log.2"))
        try Data("A".utf8).write(to: f("serve.log.1"))
        try Data(String(repeating: "D", count: 2048).utf8).write(to: log)
        let fd = open(log.path, O_WRONLY)
        defer { close(fd) }

        let rotated = LogRotation.rotateIfNeeded(
            logURL: log, fd: fd, maxBytes: 1024, keep: 3
        )

        #expect(rotated)
        #expect(read(f("serve.log.1")) == String(repeating: "D", count: 2048))
        #expect(read(f("serve.log.2")) == "A")
        #expect(read(f("serve.log.3")) == "B")
        #expect(!FileManager.default.fileExists(atPath: f("serve.log.4").path))
    }

    @Test("filesystem failure rolls back without losing the live log")
    func failureRollback() throws {
        let dir = try tempDir()
        let log = dir.appendingPathComponent("serve.log")
        let payload = String(repeating: "D", count: 2048)
        try Data(payload.utf8).write(to: log)
        let fd = open(log.path, O_WRONLY)
        defer {
            close(fd)
            chmod(dir.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }

        // Strip the inherited ACL that macOS temp dirs carry (mode bits alone
        // don't restrict access otherwise), then drop write so the rename of
        // the live log fails. Rotation must bail without touching `serve.log`.
        stripACL(dir)
        chmod(dir.path, 0o500)
        let rotated = LogRotation.rotateIfNeeded(
            logURL: log, fd: fd, maxBytes: 1024, keep: 3
        )

        #expect(rotated == false)
        let survived =
            read(log) == payload
                || read(dir.appendingPathComponent("serve.log.1")) == payload
        #expect(survived)
        let n = "x".withCString { write(fd, $0, 1) }
        #expect(n == 1)
    }

    private func stripACL(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = ["-N", url.path]
        try? p.run()
        p.waitUntilExit()
    }
}

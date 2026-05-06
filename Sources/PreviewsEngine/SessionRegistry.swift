import Darwin
import Foundation
import PreviewsMacOS

/// Cross-process registry of live preview sessions.
///
/// PreviewsMCP runs in two flavors that hold distinct session pools:
/// the stdio MCP server (one per Claude-Code-style host) and the UDS
/// daemon (`previewsmcp serve --daemon`, shared by every CLI command).
/// Without coordination, `session_list` from one mouth doesn't see
/// sessions created via the other — the user-visible "phantom session"
/// bug documented in `AGENTS.md:78-94`.
///
/// This registry pins each process's session set to a JSON file at
/// `<registryDir>/<pid>.json`. Each process writes its own file on
/// every session-set mutation; on read, every PID file is enumerated
/// and stale entries (where the named PID no longer exists) are
/// dropped. `SessionListHandler` reads the local in-memory state plus
/// `readOthers()` and returns the union.
///
/// Create-side stays split — sessions still live in the process that
/// owns the simulator/host. Only the read-side is unified.
///
/// Stale-file cleanup runs lazily during `readOthers`. Files for crashed
/// processes accumulate harmlessly until the next read picks them up.
/// We don't register an `atexit` cleanup hook because Swift's bridge
/// to it is fragile and the lazy filter is sufficient for correctness.
public actor SessionRegistry {

    /// One row in the per-process registry file. Mirrors
    /// `DaemonProtocol.SessionDTO` in shape; defined here so
    /// `PreviewsEngine` doesn't need to import `PreviewsCLI`.
    public struct Entry: Codable, Sendable, Equatable {
        public let sessionID: String
        public let platform: String
        public let sourceFilePath: String

        public init(sessionID: String, platform: String, sourceFilePath: String) {
            self.sessionID = sessionID
            self.platform = platform
            self.sourceFilePath = sourceFilePath
        }
    }

    /// On-disk file shape: a header with the writer's PID plus the
    /// session entries. The `pid` field lets readers detect a recycled
    /// PID — if the file's `pid` doesn't match its filename, we treat
    /// it as stale.
    private struct FileContents: Codable {
        let pid: Int32
        let sessions: [Entry]
    }

    private let registryDir: URL
    private let pid: Int32
    private let pidFileName: String
    private let liveCheck: @Sendable (Int32) -> Bool
    private var iosSnapshot: [Entry] = []
    private var macSnapshot: [Entry] = []

    public init(
        registryDir: URL,
        liveCheck: (@Sendable (Int32) -> Bool)? = nil,
        pid: Int32 = getpid()
    ) {
        self.registryDir = registryDir
        self.pid = pid
        self.pidFileName = "\(pid).json"
        self.liveCheck = liveCheck ?? Self.defaultLiveCheck
    }

    /// Default `kill(pid, 0)` liveness check. Returns `true` if the
    /// process exists, including the EPERM case (signalable by us or
    /// not — a live process running as a different user must not have
    /// its sessions dropped). Test code can pass a custom predicate
    /// via `init(registryDir:pid:liveCheck:)`.
    @Sendable
    private static func defaultLiveCheck(_ pid: Int32) -> Bool {
        let result = Darwin.kill(pid, 0)
        if result == 0 { return true }
        return errno != ESRCH
    }

    // MARK: - Attach

    /// Wire this registry to the iOS manager and macOS host so they
    /// publish on every session-set mutation. Call once at host
    /// construction time — both `DaemonListener.start` and
    /// `ServeCommand.runStdio` do so. Calling more than once is
    /// wasteful but not unsafe (idempotent attach + redundant
    /// initial publishes).
    public func attachTo(iosManager: IOSSessionManager, previewHost: PreviewHost) async {
        await iosManager.setRegistry(self)
        await MainActor.run {
            // weak self so the host doesn't extend the registry's life
            // beyond intended scope.
            previewHost.publishSessions = { [weak self] snapshot in
                await self?.publishMacOSSessions(snapshot)
            }
            // Trigger an initial publish so a registry attached after
            // sessions exist (e.g., reattach during integration tests)
            // doesn't lose them.
            previewHost.notifySessionsChanged()
        }
    }

    // MARK: - Publish

    /// Replace the iOS slice of our published session set and rewrite
    /// our PID file.
    public func publishIOSSessions(_ sessions: [(id: String, sourceFile: URL)]) {
        iosSnapshot = sessions.map {
            Entry(sessionID: $0.id, platform: "ios", sourceFilePath: $0.sourceFile.path)
        }
        writeOurFile()
    }

    /// Replace the macOS slice of our published session set and rewrite
    /// our PID file.
    public func publishMacOSSessions(_ sessions: [(id: String, sourceFile: URL)]) {
        macSnapshot = sessions.map {
            Entry(sessionID: $0.id, platform: "macos", sourceFilePath: $0.sourceFile.path)
        }
        writeOurFile()
    }

    /// Remove our PID file. Best-effort; safe to call multiple times.
    public func unpublish() {
        let path = registryDir.appendingPathComponent(pidFileName)
        try? FileManager.default.removeItem(at: path)
    }

    // MARK: - Read

    /// Read sessions published by other processes. Filters out stale
    /// PID files (PID no longer running, or filename/contents PID
    /// mismatch). Lazily deletes the stale files it finds.
    public func readOthers() -> [Entry] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: registryDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else {
            return []
        }

        var collected: [Entry] = []
        for url in entries where url.pathExtension == "json" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let filePID = Int32(stem) else { continue }
            // Skip our own file — we already merge in-memory.
            if filePID == pid { continue }
            // Skip stale processes (and lazily delete the file).
            guard liveCheck(filePID) else {
                try? fm.removeItem(at: url)
                continue
            }
            guard
                let data = try? Data(contentsOf: url),
                let decoded = try? JSONDecoder().decode(FileContents.self, from: data),
                decoded.pid == filePID
            else { continue }
            collected.append(contentsOf: decoded.sessions)
        }
        return collected
    }

    // MARK: - Internals

    private func writeOurFile() {
        let payload = FileContents(pid: pid, sessions: iosSnapshot + macSnapshot)
        guard let data = try? JSONEncoder().encode(payload) else { return }

        let fm = FileManager.default
        try? fm.createDirectory(
            at: registryDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let target = registryDir.appendingPathComponent(pidFileName)
        // Write atomically so concurrent readers can't observe a
        // partial file. `Data.write(options: .atomic)` writes to a
        // temp and renames into place.
        try? data.write(to: target, options: .atomic)
        // Tighten permissions explicitly. The parent directory is 0700
        // so the file is already user-private, but session entries
        // embed full filesystem paths and 0600 is one fewer place
        // someone has to look to verify that.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

}

import Foundation

public struct Guest: Sendable {
    public let endpoint: VMSSH.Endpoint
    public let adminPass: String

    public init(endpoint: VMSSH.Endpoint, adminPass: String) {
        self.endpoint = endpoint
        self.adminPass = adminPass
    }

    @discardableResult
    public func run(_ command: String, timeout: TimeInterval = 600) async throws -> SSHResult {
        try await VMSSH.exec(endpoint: endpoint, command: command, timeout: timeout)
    }

    public struct Env: Sendable, ExpressibleByStringLiteral {
        public let preamble: String
        public init(stringLiteral preamble: String) {
            self.preamble = preamble
        }

        public static let sh: Self = ""
        public static let brew: Self = "eval \"$(/opt/homebrew/bin/brew shellenv)\" && "
    }

    @discardableResult
    public func sh(_ command: String, env: Env = .sh, timeout: TimeInterval = 600) async throws
        -> String
    {
        let result = try await run(env.preamble + command, timeout: timeout)
        guard result.exitCode == 0 else {
            throw VMError(
                "remote command failed (exit \(result.exitCode)): \(command)\n\(result.stderr)"
            )
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func test(_ command: String) async throws -> Bool {
        try await run(command).exitCode == 0
    }

    @discardableResult
    public func sudo(_ command: String, timeout: TimeInterval = 600) async throws -> String {
        try await sh(
            "printf '%s\\n' \(Self.shellQuote(adminPass)) | sudo -S -p '' \(command)",
            timeout: timeout
        )
    }

    private func runLocal(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VMError("\(executable) exited \(process.terminationStatus)")
        }
    }

    private var remoteSpec: String {
        "\(endpoint.user)@\(endpoint.host)"
    }

    public func upload(localPath: String, to remotePath: String) throws {
        try runLocal(
            "/usr/bin/scp",
            ["-i", endpoint.privateKeyPath] + VMSSH.connectionFlags
                + ["-P", String(endpoint.port), localPath, "\(remoteSpec):\(remotePath)"]
        )
    }

    public func rsync(
        localDir: String,
        to remoteDir: String,
        exclude: [String] = [".build", ".git"]
    ) throws {
        let sshTransport =
            "/usr/bin/ssh -i \(endpoint.privateKeyPath) -p \(endpoint.port) "
                + VMSSH.connectionFlags.joined(separator: " ")
        var args = ["-az", "--delete", "-e", sshTransport]
        for pattern in exclude {
            args += ["--exclude", pattern]
        }
        let source = localDir.hasSuffix("/") ? localDir : localDir + "/"
        args += [source, "\(remoteSpec):\(remoteDir)/"]
        try runLocal("/usr/bin/rsync", args)
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Boot `bundle`, wait for SSH, hand a connected `Guest` to `body`, then stop
    /// the VM. Any failure after the VM starts — a setup-phase timeout, a pid-file
    /// write error, or a thrown `body` — stops it too. The pid file is cleared only
    /// once the VM is confirmed `.stopped`, so a stop that never confirms leaves a
    /// record for the caller's stale-VM reaper instead of a silently orphaned VM.
    public static func session(
        bundle: VMBundle,
        adminPass: String,
        share: VMConfiguration.DirectoryShare? = nil,
        mountAt: String? = nil,
        bootTimeout: TimeInterval = 120,
        sshTimeout: TimeInterval = 180,
        stopTimeout: TimeInterval = 120,
        _ body: (Guest) async throws -> Void
    ) async throws {
        let host = try await MainActor.run { try VMHost(bundle: bundle, share: share) }
        try await host.start()

        func stopVM() async {
            var stopped = false
            do {
                try await host.requestStop()
                try await host.waitForStop(timeout: stopTimeout)
                stopped = true
            } catch {
                Log.info("graceful shutdown failed; force-stopping")
                try? await host.forceStop()
                stopped = (try? await host.waitForStop(timeout: stopTimeout)) != nil
            }
            if stopped {
                VMPidFile.clear(bundle)
            } else {
                Log.info("VM not confirmed stopped; leaving pid file for the stale-VM reaper")
            }
        }

        do {
            try VMPidFile.write(getpid(), to: bundle)
            let ip = try await host.waitForIP(timeout: bootTimeout)
            let endpoint = VMSSH.endpoint(bundle: bundle, host: ip)
            Log.info("waiting for SSH at \(endpoint.user)@\(ip)")
            try await VMSSH.waitForReady(endpoint: endpoint, timeout: sshTimeout)
            if let mountAt, share != nil {
                try await VMSSH.mountShare(endpoint: endpoint, guestPath: mountAt)
            }
            let guest = Guest(endpoint: endpoint, adminPass: adminPass)
            try await body(guest)
        } catch {
            await stopVM()
            throw error
        }

        Log.info("stopping guest")
        await stopVM()
    }
}

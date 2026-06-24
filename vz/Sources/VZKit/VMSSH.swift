import Foundation

public struct SSHResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

/// Shells out to `/usr/bin/ssh`. We could link libssh2 / libssh, but the
/// OpenSSH CLI is already installed everywhere we run, handles host-key
/// management, ECDSA/ed25519, agent forwarding, and `~/.ssh/config`
/// overrides without us reimplementing any of it. The cost is fork+exec
/// per command — fine for our cadence.
public enum VMSSH {
    public struct Endpoint: Sendable {
        public let host: String
        public let port: Int
        public let user: String
        public let privateKeyPath: String
        public let knownHostsPath: String

        public init(
            host: String,
            port: Int = 22,
            user: String,
            privateKeyPath: String,
            knownHostsPath: String
        ) {
            self.host = host
            self.port = port
            self.user = user
            self.privateKeyPath = privateKeyPath
            self.knownHostsPath = knownHostsPath
        }
    }

    /// Construct the endpoint that a `boot`-derived IP + a bundle define.
    public static func endpoint(bundle: VMBundle, host: String, port: Int = 22) -> Endpoint {
        Endpoint(
            host: host,
            port: port,
            user: bundle.config.sshUsername,
            privateKeyPath: bundle.sshPrivateKeyURL.path,
            knownHostsPath: bundle.knownHostsURL.path
        )
    }

    /// Run a single command non-interactively, capturing stdout/stderr/exit.
    public static func exec(
        endpoint: Endpoint,
        command: String,
        timeout: TimeInterval = 60
    ) async throws -> SSHResult {
        let args = baseArgs(endpoint: endpoint) + [
            "\(endpoint.user)@\(endpoint.host)", command,
        ]
        return try await runCapturing(
            executablePath: "/usr/bin/ssh", arguments: args, timeout: timeout)
    }

    /// Run an interactive SSH session (stdin/stdout/stderr inherited from
    /// the calling process). Used by `vz ssh` with no `--` command.
    public static func execInteractive(
        endpoint: Endpoint,
        command: String? = nil,
        forceTTY: Bool = false
    ) throws -> Int32 {
        var args = baseArgs(endpoint: endpoint, allocateTTY: command == nil || forceTTY)
        args.append("\(endpoint.user)@\(endpoint.host)")
        if let command {
            args.append(command)
        }
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/ssh")
        p.arguments = args
        do {
            try p.run()
        } catch {
            throw VMError("could not spawn /usr/bin/ssh", underlying: error)
        }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Expose the virtio-fs share at `guestPath`. A macOS guest only serves
    /// content through the automount tag, and the system auto-mounts that
    /// share at `/Volumes/My Shared Files`, so we wait for it to appear and
    /// symlink `guestPath` to it rather than mounting a second time (which
    /// fails "Resource busy"). Uses `sudo -n` (passwordless sudo, devbox has it).
    public static func mountShare(
        endpoint: Endpoint,
        guestPath: String
    ) async throws {
        let automount = VMConfiguration.macOSAutomountPath
        var appeared = false
        for _ in 0..<15 {
            let probe = try await exec(
                endpoint: endpoint, command: "test -d \(Guest.shellQuote(automount))", timeout: 10)
            if probe.exitCode == 0 {
                appeared = true
                break
            }
            try await Task.sleep(for: .seconds(2))
        }
        guard appeared else {
            throw VMError("virtio-fs share did not auto-mount at \(automount)")
        }
        try await Task.sleep(for: .seconds(2))
        let result = try await exec(
            endpoint: endpoint,
            command:
                "sudo -n rm -f \(Guest.shellQuote(guestPath)) "
                + "&& sudo -n ln -sfn \(Guest.shellQuote(automount)) \(Guest.shellQuote(guestPath))",
            timeout: 15)
        guard result.exitCode == 0 else {
            throw VMError(
                "linking \(guestPath) -> \(automount) failed (exit \(result.exitCode)): \(result.stderr)"
            )
        }
    }

    /// Poll until SSH accepts a connection (`exec true` returns 0).
    public static func waitForReady(
        endpoint: Endpoint,
        timeout: TimeInterval = 180,
        pollInterval: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastDiag = "ssh not yet reachable"
        while Date() < deadline {
            do {
                let result = try await exec(endpoint: endpoint, command: "true", timeout: 5)
                if result.exitCode == 0 { return }
                lastDiag = "ssh exit \(result.exitCode): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            } catch {
                lastDiag = String(describing: error)
            }
            Log.debug(lastDiag)
            try await Task.sleep(for: .seconds(pollInterval))
        }
        throw VMError(
            "SSH did not become ready within \(Int(timeout))s for \(endpoint.user)@\(endpoint.host):\(endpoint.port) (last: \(lastDiag))"
        )
    }

    static let connectionFlags = [
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "StrictHostKeyChecking=no",
        "-o", "IdentitiesOnly=yes",
        "-o", "LogLevel=ERROR",
    ]

    private static func baseArgs(endpoint: Endpoint, allocateTTY: Bool = false) -> [String] {
        var args = ["-i", endpoint.privateKeyPath, "-p", "\(endpoint.port)"]
        args += connectionFlags
        args += [
            "-o", "PasswordAuthentication=no",
            "-o", "PreferredAuthentications=publickey",
            "-o", "ServerAliveInterval=15",
            "-o", "ConnectTimeout=5",
        ]
        if allocateTTY {
            args.append("-t")
        }
        return args
    }

    /// Sendable holder for the mutable accumulators inside `runCapturing`.
    /// `Process` and `Pipe` are not Sendable in Swift 6, but we never
    /// share them across this task — they live and die inside the detached
    /// closure. The `@unchecked Sendable` is the cost of that locality.
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private static func runCapturing(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> SSHResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(filePath: executablePath)
            process.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Drain pipes concurrently so a full 64KiB buffer can't wedge
            // the child. We don't care about ordering between the two
            // streams; we just need to keep reading.
            let outBox = Box(Data())
            let errBox = Box(Data())
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    outBox.value.append(chunk)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    errBox.value.append(chunk)
                }
            }

            do {
                try process.run()
            } catch {
                throw VMError("could not spawn \(executablePath)", underlying: error)
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                process.terminate()
                try? await Task.sleep(for: .milliseconds(250))
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
            }
            // Drain any tail bytes the handlers haven't pulled yet.
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            if let tail = try? outPipe.fileHandleForReading.readToEnd() { outBox.value.append(tail) }
            if let tail = try? errPipe.fileHandleForReading.readToEnd() { errBox.value.append(tail) }

            return SSHResult(
                exitCode: process.terminationStatus,
                stdout: String(data: outBox.value, encoding: .utf8) ?? "",
                stderr: String(data: errBox.value, encoding: .utf8) ?? ""
            )
        }.value
    }
}

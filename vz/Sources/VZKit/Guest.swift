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

    public enum Env: Sendable {
        case sh
        case brew

        var preamble: String {
            switch self {
            case .sh: return ""
            case .brew: return "eval \"$(/opt/homebrew/bin/brew shellenv)\" && "
            }
        }
    }

    @discardableResult
    public func sh(_ command: String, env: Env = .sh, timeout: TimeInterval = 600) async throws
        -> String
    {
        let result = try await run(env.preamble + command, timeout: timeout)
        guard result.exitCode == 0 else {
            throw VMError(
                "remote command failed (exit \(result.exitCode)): \(command)\n\(result.stderr)")
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
            timeout: timeout)
    }

    public func upload(localPath: String, to remotePath: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/scp")
        process.arguments = [
            "-i", endpoint.privateKeyPath,
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=no",
            "-P", String(endpoint.port),
            localPath, "\(endpoint.user)@\(endpoint.host):\(remotePath)",
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VMError("scp exited \(process.terminationStatus)")
        }
    }

    public func uploadTree(localDir: String, to remoteDir: String) async throws {
        let name = (localDir as NSString).lastPathComponent
        let hostTar = NSTemporaryDirectory() + "vzkit-tree-\(name).tar"
        let remoteTar = "/tmp/vzkit-tree-\(name).tar"
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-cf", hostTar, "-C", localDir, "."]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            throw VMError("tar of \(localDir) exited \(tar.terminationStatus)")
        }
        defer { try? FileManager.default.removeItem(atPath: hostTar) }
        try upload(localPath: hostTar, to: remoteTar)
        try await sh(
            "rm -rf \(remoteDir) && mkdir -p \(remoteDir) "
                + "&& tar -xf \(remoteTar) -C \(remoteDir) && rm -f \(remoteTar)")
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Boot `bundle`, wait for SSH, hand a connected `Guest` to `body`, then
    /// shut the VM down. On a thrown body the VM is force-stopped; on success
    /// it is asked to stop gracefully and force-stopped if that times out.
    public static func session(
        bundle: VMBundle,
        adminPass: String,
        bootTimeout: TimeInterval = 120,
        sshTimeout: TimeInterval = 180,
        stopTimeout: TimeInterval = 120,
        _ body: (Guest) async throws -> Void
    ) async throws {
        let host = try await MainActor.run { try VMHost(bundle: bundle) }
        try await host.start()
        let ip = try await host.waitForIP(timeout: bootTimeout)
        let endpoint = VMSSH.endpoint(bundle: bundle, host: ip)
        Log.info("waiting for SSH at \(endpoint.user)@\(ip)")
        try await VMSSH.waitForReady(endpoint: endpoint, timeout: sshTimeout)

        let guest = Guest(endpoint: endpoint, adminPass: adminPass)
        do {
            try await body(guest)
        } catch {
            try? await host.forceStop()
            throw error
        }

        Log.info("stopping guest")
        do {
            try await host.requestStop()
            try await host.waitForStop(timeout: stopTimeout)
        } catch {
            Log.info("graceful shutdown timed out; force-stopping")
            try? await host.forceStop()
        }
    }
}

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

    @discardableResult
    public func sh(_ command: String, timeout: TimeInterval = 600) async throws -> String {
        let result = try await run(command, timeout: timeout)
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

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

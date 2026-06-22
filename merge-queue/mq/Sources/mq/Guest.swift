import Foundation
import VZKit

struct MQError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

struct Guest {
    let endpoint: VMSSH.Endpoint
    let adminPass: String

    @discardableResult
    func run(_ command: String, timeout: TimeInterval = 600) async throws -> SSHResult {
        try await VMSSH.exec(endpoint: endpoint, command: command, timeout: timeout)
    }

    @discardableResult
    func sh(_ command: String, timeout: TimeInterval = 600) async throws -> String {
        let result = try await run(command, timeout: timeout)
        guard result.exitCode == 0 else {
            throw MQError("remote command failed (exit \(result.exitCode)): \(command)\n\(result.stderr)")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func test(_ command: String) async throws -> Bool {
        try await run(command).exitCode == 0
    }

    @discardableResult
    func sudo(_ command: String, timeout: TimeInterval = 600) async throws -> String {
        try await sh("printf '%s\\n' \(Self.quote(adminPass)) | sudo -S -p '' \(command)", timeout: timeout)
    }

    func upload(localPath: String, to remotePath: String) async throws {
        let args = [
            "-i", endpoint.privateKeyPath,
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=no",
            "-P", String(endpoint.port),
            localPath,
            "\(endpoint.user)@\(endpoint.host):\(remotePath)",
        ]
        try Self.runProcess("/usr/bin/scp", args)
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runProcess(_ path: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MQError("\(path) exited \(process.terminationStatus)")
        }
    }
}

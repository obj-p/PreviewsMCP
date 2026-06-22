import Foundation
import VZKit

struct ScriptError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct Guest {
    let endpoint: VMSSH.Endpoint
    let adminPass: String

    @discardableResult
    func sh(_ command: String, timeout: TimeInterval = 600) async throws -> String {
        let result = try await VMSSH.exec(endpoint: endpoint, command: command, timeout: timeout)
        guard result.exitCode == 0 else {
            throw ScriptError("remote failed (\(result.exitCode)): \(command)\n\(result.stderr)")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func test(_ command: String) async throws -> Bool {
        try await VMSSH.exec(endpoint: endpoint, command: command).exitCode == 0
    }

    @discardableResult
    func sudo(_ command: String, timeout: TimeInterval = 600) async throws -> String {
        try await sh("printf '%s\\n' \(shellQuote(adminPass)) | sudo -S -p '' \(command)", timeout: timeout)
    }

    func upload(_ localPath: String, to remotePath: String) throws {
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
            throw ScriptError("scp exited \(process.terminationStatus)")
        }
    }
}

func kcpassword(_ password: String) -> Data {
    let cipher: [UInt8] = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F]
    var bytes = Array(password.utf8)
    let remainder = bytes.count % 12
    bytes += Array(repeating: 0, count: remainder == 0 ? 12 : 12 - remainder)
    for index in bytes.indices {
        bytes[index] ^= cipher[index % cipher.count]
    }
    return Data(bytes)
}

func provisionToolchain(
    _ guest: Guest, xip: String, adminUser: String = "admin",
    xcodeApp: String = "/Applications/Xcode.app"
) async throws {
    if try await guest.test("test -d \(xcodeApp)") {
        print("==> Xcode already present, skipping install")
    } else {
        print("==> streaming xip into guest")
        try guest.upload(xip, to: "/tmp/Xcode.xip")
        print("==> expanding Xcode in guest")
        try await guest.sh("cd /tmp && rm -rf Xcode.app && xip -x Xcode.xip", timeout: 1800)
        try await guest.sudo("rm -rf \(xcodeApp) && mv /tmp/Xcode.app \(xcodeApp)")
        try await guest.sh("rm -f /tmp/Xcode.xip")
        print("==> selecting toolchain and accepting license")
        try await guest.sudo("xcode-select -s \(xcodeApp)")
        try await guest.sudo("xcodebuild -license accept")
        try await guest.sudo("xcodebuild -runFirstLaunch", timeout: 1800)
    }

    print("==> enabling passwordless sudo for \(adminUser)")
    try await guest.sudo(
        "bash -c 'echo \"\(adminUser) ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/\(adminUser) "
            + "&& chmod 440 /etc/sudoers.d/\(adminUser)'")

    print("==> installing Homebrew, bazelisk, mise")
    try await guest.sh(
        "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL "
            + "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"",
        timeout: 1800)
    try await guest.sh(
        "eval \"$(/opt/homebrew/bin/brew shellenv)\" && brew install bazelisk mise", timeout: 1800)

    print("==> enabling autologin for \(adminUser)")
    let encoded = kcpassword(guest.adminPass).base64EncodedString()
    try await guest.sudo(
        "bash -c 'echo \(encoded) | base64 -D > /etc/kcpassword && chmod 600 /etc/kcpassword "
            + "&& defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser \(adminUser)'")

    print("==> verifying swift toolchain in guest")
    print(try await guest.sh("xcrun swift --version"))
    print("==> toolchain provisioning complete")
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(
        Data("usage: vz run toolchain.swift <bundle> <xip> [restoreFrom] [snapshot]\n".utf8))
    exit(2)
}
let bundlePath = arguments[1]
let xipPath = arguments[2]
let restoreFrom: String? = arguments.count > 3 ? arguments[3] : nil
let snapshotName = arguments.count > 4 ? arguments[4] : "post-toolchain"
let adminPass = "vzvz"

let bundle = try VMBundle(directory: URL(filePath: bundlePath))
if let restoreFrom {
    print("==> restoring \(restoreFrom)")
    try SnapshotStore.restore(name: restoreFrom, in: bundle)
}

let host = try await MainActor.run { try VMHost(bundle: bundle) }
try await host.start()
let ip = try await host.waitForIP(timeout: 120)
let endpoint = VMSSH.endpoint(bundle: bundle, host: ip)
print("==> waiting for SSH at \(endpoint.user)@\(ip)")
try await VMSSH.waitForReady(endpoint: endpoint, timeout: 180)

let guest = Guest(endpoint: endpoint, adminPass: adminPass)
do {
    try await provisionToolchain(guest, xip: xipPath)
} catch {
    try? await host.forceStop()
    throw error
}

print("==> stopping guest")
do {
    try await host.requestStop()
    try await host.waitForStop(timeout: 120)
} catch {
    print("==> graceful shutdown timed out; force-stopping")
    try? await host.forceStop()
}
_ = try SnapshotStore.take(name: snapshotName, of: bundle)
print("snapshot '\(snapshotName)' taken")

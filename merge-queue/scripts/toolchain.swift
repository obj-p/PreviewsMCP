import Foundation
import VZKit

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
        step("Xcode already present, skipping install")
    } else {
        step("streaming xip into guest")
        try guest.upload(localPath: xip, to: "/tmp/Xcode.xip")
        step("expanding Xcode in guest")
        try await guest.sh("cd /tmp && rm -rf Xcode.app && xip -x Xcode.xip", timeout: 1800)
        try await guest.sudo("rm -rf \(xcodeApp) && mv /tmp/Xcode.app \(xcodeApp)")
        try await guest.sh("rm -f /tmp/Xcode.xip")
        step("selecting toolchain and accepting license")
        try await guest.sudo("xcode-select -s \(xcodeApp)")
        try await guest.sudo("xcodebuild -license accept")
        try await guest.sudo("xcodebuild -runFirstLaunch", timeout: 1800)
    }

    step("enabling passwordless sudo for \(adminUser)")
    try await guest.sudo(
        "bash -c 'echo \"\(adminUser) ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/\(adminUser) "
            + "&& chmod 440 /etc/sudoers.d/\(adminUser)'")

    step("installing Homebrew, bazelisk, mise")
    try await guest.sh(
        "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL "
            + "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"",
        timeout: 1800)
    try await guest.brew("brew install bazelisk mise", timeout: 1800)

    step("enabling autologin for \(adminUser)")
    let encoded = kcpassword(guest.adminPass).base64EncodedString()
    try await guest.sudo(
        "bash -c 'echo \(encoded) | base64 -D > /etc/kcpassword && chmod 600 /etc/kcpassword "
            + "&& defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser \(adminUser)'")

    step("verifying swift toolchain in guest")
    print(try await guest.sh("xcrun swift --version"))
    step("toolchain provisioning complete")
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(
        Data("usage: vz run toolchain.swift <bundle> <xip>\n".utf8))
    exit(2)
}
let bundle = try VMBundle(directory: URL(filePath: arguments[1]))
let xipPath = arguments[2]

try await Guest.session(bundle: bundle, adminPass: "vzvz") { guest in
    try await provisionToolchain(guest, xip: xipPath)
}

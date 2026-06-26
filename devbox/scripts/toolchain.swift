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

func provisionToolchain(_ guest: Guest, xip: String, brewfile: String) async throws {
    let adminUser = "admin"
    let xcodeApp = "/Applications/Xcode-26.2.0.app"
    if try await guest.test("test -d \(xcodeApp)") {
        step("Xcode already present, skipping install")
    } else {
        step("streaming xip into guest")
        try guest.upload(localPath: xip, to: "/tmp/Xcode.xip")
        step("expanding Xcode in guest")
        try await guest.sh("cd /tmp && rm -rf Xcode.app && xip -x Xcode.xip", timeout: 1800)
        try await guest.sudo("rm -rf \(xcodeApp) && mv /tmp/Xcode.app \(xcodeApp)")
        try await guest.sh("rm -f /tmp/Xcode.xip")
        step("accepting license and running first launch")
        try await guest.sudo("xcode-select -s \(xcodeApp)")
        try await guest.sudo("xcodebuild -license accept")
        try await guest.sudo("xcodebuild -runFirstLaunch", timeout: 1800)
    }

    step("verifying Xcode 26.2 is installed")
    let sdkVersion = try await guest.sh(
        "DEVELOPER_DIR=\(xcodeApp)/Contents/Developer xcrun --sdk macosx --show-sdk-version"
    )
    guard sdkVersion.hasPrefix("26.2") else {
        throw VMError("expected macOS SDK 26.2 from \(xcodeApp), got \(sdkVersion)")
    }

    step("enabling passwordless sudo for \(adminUser)")
    try await guest.sudo(
        "bash -c 'echo \"\(adminUser) ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/\(adminUser) "
            + "&& chmod 440 /etc/sudoers.d/\(adminUser)'"
    )

    step("pinning Xcode via boot LaunchDaemon")
    let xcodeSelectPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    <key>Label</key><string>com.devbox.xcode-select</string>
    <key>ProgramArguments</key>
    <array>
    <string>/usr/bin/xcode-select</string>
    <string>-s</string>
    <string>\(xcodeApp)</string>
    </array>
    <key>RunAtLoad</key><true/>
    </dict>
    </plist>
    """
    let xcodeSelectPlistHex = xcodeSelectPlist.utf8
        .map { String(format: "%02x", $0) }
        .joined()
    try await guest.sh(
        "printf '\(xcodeSelectPlistHex)' | xxd -r -p | "
            + "sudo tee /Library/LaunchDaemons/com.devbox.xcode-select.plist > /dev/null && "
            + "sudo chmod 644 /Library/LaunchDaemons/com.devbox.xcode-select.plist && "
            + "sudo chown root:wheel /Library/LaunchDaemons/com.devbox.xcode-select.plist && "
            + "sudo launchctl bootstrap system /Library/LaunchDaemons/com.devbox.xcode-select.plist"
    )

    step("installing Homebrew")
    try await guest.sh(
        "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL "
            + "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"",
        timeout: 1800
    )
    step("installing tools from Brewfile via brew bundle")
    try guest.upload(localPath: brewfile, to: "/tmp/Brewfile")
    try await guest.sh("brew bundle --file=/tmp/Brewfile", env: .brew, timeout: 1800)

    step("enabling autologin for \(adminUser)")
    let encoded = kcpassword(guest.adminPass).base64EncodedString()
    try await guest.sudo(
        "bash -c 'echo \(encoded) | base64 -D > /etc/kcpassword && chmod 600 /etc/kcpassword "
            + "&& defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser \(adminUser)'"
    )

    step("verifying swift toolchain in guest")
    print(try await guest.sh("xcrun swift --version"))
    step("toolchain provisioning complete")
}

let script = Script(usage: "vz run toolchain.swift <bundle> <xip> <brewfile>", min: 4)
let bundle = try script.bundle()
let xipPath = script[arg: 2]
let brewfilePath = script[arg: 3]

try await Guest.session(bundle: bundle, adminPass: "vzvz") { guest in
    try await provisionToolchain(guest, xip: xipPath, brewfile: brewfilePath)
}

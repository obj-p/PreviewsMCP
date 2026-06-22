import Foundation
import VZKit

func provisionIOS(_ guest: Guest, xcodeApp: String = "/Applications/Xcode.app") async throws {
    try await guest.sudo("xcode-select -s \(xcodeApp)")

    if try await guest.test("xcrun simctl list devices available 2>/dev/null | grep -qi iPhone") {
        print("==> an iPhone simulator is already available")
    } else {
        print("==> downloading iOS simulator runtime (multi-GB, slow)")
        try await guest.sh("xcodebuild -downloadPlatform iOS", timeout: 5400)
    }

    print("==> verifying an iPhone simulator is available")
    try await guest.sh("xcrun simctl list devices available | grep -i iPhone")
    print("==> ios provisioning complete")
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: vz run ios.swift <bundle>\n".utf8))
    exit(2)
}
let bundle = try VMBundle(directory: URL(filePath: arguments[1]))

try await Guest.session(bundle: bundle, adminPass: "vzvz") { guest in
    try await provisionIOS(guest)
}

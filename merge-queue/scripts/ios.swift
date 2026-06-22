import Foundation
import VZKit

func provisionIOS(_ guest: Guest) async throws {
    try await guest.sudo("xcode-select -s /Applications/Xcode.app")

    if try await guest.test("xcrun simctl list devices available 2>/dev/null | grep -qi iPhone") {
        step("an iPhone simulator is already available")
    } else {
        step("downloading iOS simulator runtime (multi-GB, slow)")
        try await guest.sh("xcodebuild -downloadPlatform iOS", timeout: 5400)
    }

    step("verifying an iPhone simulator is available")
    try await guest.sh("xcrun simctl list devices available | grep -i iPhone")
    step("ios provisioning complete")
}

let script = Script(usage: "vz run ios.swift <bundle>", min: 2)
let bundle = try script.bundle()

try await Guest.session(bundle: bundle, adminPass: "vzvz") { guest in
    try await provisionIOS(guest)
}

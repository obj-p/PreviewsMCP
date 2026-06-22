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

let host = try await MainActor.run { try VMHost(bundle: bundle) }
try await host.start()
let ip = try await host.waitForIP(timeout: 120)
let endpoint = VMSSH.endpoint(bundle: bundle, host: ip)
print("==> waiting for SSH at \(endpoint.user)@\(ip)")
try await VMSSH.waitForReady(endpoint: endpoint, timeout: 180)

let guest = Guest(endpoint: endpoint, adminPass: "vzvz")
do {
    try await provisionIOS(guest)
} catch {
    try? await host.forceStop()
    throw error
}

print("==> stopping guest")
do {
    try host.requestStop()
    try await host.waitForStop(timeout: 120)
} catch {
    print("==> graceful shutdown timed out; force-stopping")
    try? await host.forceStop()
}

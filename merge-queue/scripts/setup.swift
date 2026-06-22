import AppKit
import Foundation
import VZKit

func rule(_ match: String, terminal: Bool = false, _ actions: [SetupAssistantSequence.Step])
    -> ScreenRule
{
    ScreenRule(match: match, actions: actions, terminal: terminal)
}

let saPlan: [ScreenRule] = [
    rule("Welcome", [.key(.returnKey)]),
    rule("Select Your Country", [
        .clickByText("Select Your Country"), .wait(seconds: 2),
        .type("united states"), .wait(seconds: 2),
        .clickByText("United States"), .wait(seconds: 1),
        .modifiedKey(modifier: .shift, key: .tab), .wait(seconds: 1),
        .key(.space),
    ]),
    rule("Transfer Your Data", [
        .clickByText("Set up as new"), .wait(seconds: 2), .clickByText("Continue"),
    ]),
    rule("Written and Spoken Languages", [.clickByText("Continue")]),
    rule("Accessibility", [.clickByText("Not Now")]),
    rule("Data & Privacy", [.clickByText("Continue")]),
    rule("Create a Mac Account", [
        .clickByText("Full Name"), .wait(seconds: 1),
        .type("admin"), .key(.tab), .key(.tab), .type("vzvz"),
        .clickByText("Verify Password"), .type("vzvz"), .wait(seconds: 1),
        .clickByText("Continue"),
    ]),
    rule("Sign In to Your Apple Account", [
        .clickByText("Other Sign-In Options"), .wait(seconds: 2),
        .clickByText("Sign in Later in Settings"), .wait(seconds: 2),
        .clickByText("Skip"),
    ]),
    rule("Terms and Conditions", [
        .clickByText("Agree"), .wait(seconds: 2), .clickByText("Agree"),
    ]),
    rule("Age Range", [
        .clickByText("Adult"), .wait(seconds: 1), .clickByText("Continue"),
    ]),
    rule("Location Services", [
        .clickByText("Continue"), .wait(seconds: 2), .clickByText("Don't Use"),
    ]),
    rule("Time Zone", [.clickByText("Continue")]),
    rule("Analytics", [.clickByText("Continue")]),
    rule("Screen Time", [.clickByText("Set Up Later")]),
    rule("FileVault", [
        .clickByText("Not Now"), .wait(seconds: 2), .clickByText("Continue"),
    ]),
    rule("Choose Your Look", [.clickByText("Continue")]),
    rule("Update Mac", [.clickByText("Continue")]),
    rule("Language", [.key(.returnKey)]),
    rule("Finder", terminal: true, []),
    rule("Get Started", [.clickByText("Get Started")]),
    rule("Continue", [.key(.returnKey)]),
]

func driveSetup(bundle: VMBundle, outputDir: URL) async throws {
    let host = try await MainActor.run { try FirstBootHost(bundle: bundle, debugVisible: true) }
    try await host.start()
    do {
        let vnc = try await MainActor.run { try VNCSPI.start(virtualMachine: host.machine, port: 0) }
        defer { Task { @MainActor in vnc.stop() } }
        let client = RFBClient()
        try client.connect(to: .init(host: "127.0.0.1", port: vnc.port), timeout: 10)
        try client.handshake()
        try await SetupAssistantSequence.runDispatchVNC(
            rules: saPlan, host: host, client: client,
            screenshotDir: outputDir, maxIterations: 80)
    } catch {
        try? await host.forceStop()
        await MainActor.run { host.close() }
        throw error
    }
    try? await host.forceStop()
    await MainActor.run { host.close() }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(
        Data("usage: vz run setup.swift <bundle> [restoreFrom] [retries]\n".utf8))
    exit(2)
}
let bundle = try VMBundle(directory: URL(filePath: arguments[1]))
let restoreFrom = arguments.count > 2 ? arguments[2] : "base"
let retries = arguments.count > 3 ? (Int(arguments[3]) ?? 3) : 3
let outputDir = URL(filePath: "/tmp/mq-setup")
try? FileManager.default.removeItem(at: outputDir)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task {
    let maxAttempts = retries + 1
    for attempt in 1...maxAttempts {
        do {
            print("==> setup attempt \(attempt)/\(maxAttempts): restoring \(restoreFrom)")
            try SnapshotStore.restore(name: restoreFrom, in: bundle)
            try await driveSetup(bundle: bundle, outputDir: outputDir)
            print("==> setup assistant complete")
            Darwin.exit(0)
        } catch {
            FileHandle.standardError.write(Data("attempt \(attempt) failed: \(error)\n".utf8))
        }
    }
    FileHandle.standardError.write(Data("setup failed after \(maxAttempts) attempts\n".utf8))
    Darwin.exit(1)
}
app.run()

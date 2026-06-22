import ArgumentParser
import Foundation
import VZKit

@main
struct MQ: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mq",
        abstract: "Merge-queue VM control — a Swift consumer of VZKit (prototype).",
        subcommands: [Toolchain.self, Setup.self]
    )
}

struct Toolchain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Provision the Xcode toolchain + Homebrew + autologin, then snapshot.")

    @Argument(help: "Path to the VM bundle.") var bundlePath: String
    @Option(help: "Path to the Xcode .xip on the host.") var xcodeXip: String
    @Option(help: "Admin account password.") var adminPass: String = "vzvz"
    @Option(help: "Snapshot to restore before provisioning.") var restoreFrom: String?
    @Option(help: "Snapshot to take when done.") var snapshot: String = "post-toolchain"

    func run() async throws {
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
            try await Provision.toolchain(guest, xcodeXip: xcodeXip)
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
        _ = try SnapshotStore.take(name: snapshot, of: bundle)
        print("snapshot '\(snapshot)' taken")
    }
}

struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drive Setup Assistant via the typed Swift screen plan.")

    @Argument(help: "Path to the VM bundle.") var bundlePath: String
    @Option(help: "Snapshot to restore before driving Setup Assistant.") var restoreFrom: String?
    @Option(help: "Snapshot to take when done.") var snapshot: String?
    @Option(help: "Directory for per-iteration screenshots.") var outputDir: String = "/tmp/mq-setup"
    @Option(help: "Maximum dispatch iterations.") var maxIterations: Int = 80

    func run() async throws {
        let bundle = try VMBundle(directory: URL(filePath: bundlePath))
        if let restoreFrom {
            print("==> restoring \(restoreFrom)")
            try SnapshotStore.restore(name: restoreFrom, in: bundle)
        }
        let outDir = URL(filePath: outputDir)
        try? FileManager.default.removeItem(at: outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let host = try await MainActor.run { try FirstBootHost(bundle: bundle, debugVisible: false) }
        try await host.start()
        do {
            let vnc = try await MainActor.run { try VNCSPI.start(virtualMachine: host.machine, port: 0) }
            defer { Task { @MainActor in vnc.stop() } }
            let client = RFBClient()
            try client.connect(to: .init(host: "127.0.0.1", port: vnc.port), timeout: 10)
            try client.handshake()
            try await SetupAssistantSequence.runDispatchVNC(
                rules: SAPlan.macOS_26_5_1, host: host, client: client,
                screenshotDir: outDir, maxIterations: maxIterations)
        } catch {
            try? await host.forceStop()
            await MainActor.run { host.close() }
            throw error
        }

        try? await host.forceStop()
        await MainActor.run { host.close() }
        if let snapshot {
            _ = try SnapshotStore.take(name: snapshot, of: bundle)
            print("snapshot '\(snapshot)' taken")
        }
    }
}

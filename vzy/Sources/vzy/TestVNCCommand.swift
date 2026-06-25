import AppKit
import ArgumentParser
import Darwin
import Foundation
import VZKit

/// Phase 11d smoke test. Boots a bundle with a hidden NSWindow
/// attached (for `screencapture` only — VNC is the input path), starts
/// the in-process `_VZVNCServer`, connects an RFB client to the bound
/// port, sends a single Tab keysym, then screenshots before/after.
///
/// If the after-screenshot shows SA advanced (Welcome → Language for a
/// fresh boot, or any other observable state change), the VNC
/// transport works and we can build the full SA sequence on top of it.
struct TestVNCCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-vnc",
        abstract: "Phase 11d smoke test: boot + start VNC + send Tab via RFB + screenshot."
    )

    @OptionGroup var bundle: BundleArgument

    @Option(name: .long, help: "Seconds to wait for Setup Assistant to render before the first screenshot.")
    var renderWait: Double = 30

    @Option(name: .long, help: "Number of Tab keysyms to send via RFB between the screenshots.")
    var tabCount: Int = 1

    @Option(name: .long, help: "Seconds between Tab keysyms.")
    var tabGap: Double = 0.25

    @Option(name: .long, help: "Seconds to wait after the last Tab before the after-screenshot.")
    var settleWait: Double = 5

    @Option(name: .long, help: "Directory to write before.png and after.png.")
    var outputDir: String = "/tmp/vz-vnctest"

    func run() async throws {
        let bundle = try bundle.load()
        let outDir = URL(filePath: (outputDir as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // Hidden NSWindow + VZVirtualMachineView is kept for screencapture
        // only. The VZ machine drives both the view and the VNC server;
        // input goes through VNC.
        let host = try await MainActor.run { try FirstBootHost(bundle: bundle, debugVisible: true) }
        try await host.start()

        let vnc = try await MainActor.run {
            try VNCSPI.start(virtualMachine: host.machine, port: 0)
        }
        defer { Task { @MainActor in vnc.stop() } }

        Log.info("VNC server listening on localhost:\(vnc.port)")

        let client = RFBClient()
        try client.connect(to: .init(host: "127.0.0.1", port: vnc.port), timeout: 10)
        try client.handshake()
        Log.info("RFB client handshake OK")

        Log.info("waiting \(Int(renderWait))s for Setup Assistant to render…")
        try await Task.sleep(for: .seconds(renderWait))

        let before = outDir.appending(path: "before.png")
        try await MainActor.run { try Screenshot.captureWindow(host.window, to: before) }
        Log.info("before screenshot → \(before.path)")

        Log.info("sending \(tabCount) Tab keysym(s) via RFB…")
        for i in 1 ... tabCount {
            try client.tapKey(keysym: RFBClient.KeySym.tab)
            Log.debug("RFB tap Tab \(i)/\(tabCount)")
            try await Task.sleep(for: .seconds(tabGap))
        }

        Log.info("waiting \(Int(settleWait))s for the guest to react…")
        try await Task.sleep(for: .seconds(settleWait))

        let after = outDir.appending(path: "after.png")
        try await MainActor.run { try Screenshot.captureWindow(host.window, to: after) }
        Log.info("after screenshot → \(after.path)")

        Log.info("force-stopping VM (SA-pending; no graceful path)")
        try? await host.forceStop()
        await MainActor.run { host.close() }

        print(before.path)
        print(after.path)
    }
}

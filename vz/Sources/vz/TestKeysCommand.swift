import AppKit
import ArgumentParser
import Darwin
import Foundation
import VZKit

/// Verification harness for phase 11b: boots a bundle with a VISIBLE
/// window (so `screencapture` can see the framebuffer), waits for
/// Setup Assistant to render, takes a "before" screenshot, sends N
/// Tab keystrokes, waits for the UI to advance, takes an "after"
/// screenshot, then stops.
///
/// If the before/after screenshots differ at SA's focused-element
/// indicator, `NSApp.postEvent` is successfully delivering keystrokes
/// to the `VZVirtualMachineView`. If they're identical, NSEvent
/// doesn't reach the guest from a programmatically-managed window
/// and we fall back to the private `_VZVNCServer` SPI for phase 11c.
struct TestKeysCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-keys",
        abstract: "Phase 11b verification: visible-window boot + screencaptured key delivery."
    )

    @OptionGroup var bundle: BundleArgument

    @Option(name: .long, help: "Seconds to wait for Setup Assistant to render before the first screenshot.")
    var renderWait: Double = 30

    @Option(name: .long, help: "Number of Tab keystrokes to send between the before/after screenshots.")
    var tabCount: Int = 5

    @Option(name: .long, help: "Seconds between each Tab keystroke.")
    var tabGap: Double = 0.25

    @Option(name: .long, help: "Seconds to wait after the last Tab before the after-screenshot.")
    var settleWait: Double = 3

    @Option(name: .long, help: "Directory to write before.png and after.png.")
    var outputDir: String = "/tmp/vz-keytest"

    func run() async throws {
        let bundle = try bundle.load()
        let outDir = URL(filePath: (outputDir as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let host = try await MainActor.run { try FirstBootHost(bundle: bundle, debugVisible: true) }
        try await host.start()

        Log.info("waiting \(Int(renderWait))s for Setup Assistant to render…")
        try await Task.sleep(for: .seconds(renderWait))

        let before = outDir.appending(path: "before.png")
        try await MainActor.run { try screenshotWindow(host: host, to: before) }
        Log.info("before screenshot → \(before.path)")

        Log.info("sending \(tabCount) Tab keystrokes (\(tabGap)s gap)…")
        let scripter = await MainActor.run { host.keyboardScripter() }
        for i in 1...tabCount {
            await MainActor.run { scripter.send(.tab) }
            Log.debug("sent Tab \(i)/\(tabCount)")
            try await Task.sleep(for: .seconds(tabGap))
        }

        Log.info("waiting \(Int(settleWait))s for UI to settle…")
        try await Task.sleep(for: .seconds(settleWait))

        let after = outDir.appending(path: "after.png")
        try await MainActor.run { try screenshotWindow(host: host, to: after) }
        Log.info("after screenshot → \(after.path)")

        Log.info("force-stopping VM (Setup-Assistant-pending; no graceful path)")
        try? await host.forceStop()
        await MainActor.run { host.close() }

        print(before.path)
        print(after.path)
    }

    /// Capture just the host's window by its CGWindowID. Falls back to
    /// a region screenshot of the window's frame if the windowID path
    /// returns nothing.
    @MainActor
    private func screenshotWindow(host: FirstBootHost, to url: URL) throws {
        let windowID = CGWindowID(host.window.windowNumber)
        // `screencapture -l <windowID>` captures exactly that window's
        // bitmap, including off-screen positions. -x silences the
        // shutter sound; -t png picks the format.
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-t", "png", "-l", "\(windowID)", url.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw VMError(
                "screencapture exited \(process.terminationStatus): \(errStr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VMError("screencapture exited 0 but produced no file at \(url.path)")
        }
    }
}

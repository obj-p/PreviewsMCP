import ArgumentParser
import Darwin
import Foundation
import VZKit

/// Foreground-blocking boot. Drops the user back at their terminal while
/// the VZ runloop drives the VM; another shell connects via `vz
/// ssh`. ^C requests graceful shutdown; if it doesn't reach `.stopped`
/// within the timeout, we force-stop and exit non-zero.
///
/// `--with-display` switches to a `FirstBootHost`-driven path that
/// attaches the VM to a hidden off-screen `NSWindow`. Used today to
/// boot a freshly-installed bundle into Setup Assistant for manual or
/// scripted (#11b) keyboard interaction. Implies `--skip-ssh-wait`
/// because a Setup-Assistant-pending bundle has no SSH yet.
struct BootCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot",
        abstract: "Boot a bundle and block until SIGINT/SIGTERM."
    )

    @OptionGroup var bundle: BundleArgument

    @Option(name: .long, help: "Seconds to wait for the guest's DHCP lease.")
    var ipTimeout: Double = 120

    @Option(name: .long, help: "Seconds to wait for SSH to accept connections.")
    var sshTimeout: Double = 180

    @Option(name: .long, help: "Seconds to wait for graceful shutdown before force-stop.")
    var shutdownTimeout: Double = 60

    @Flag(name: .long, help: "Skip the SSH-ready wait — return as soon as DHCP lease is seen.")
    var skipSSHWait: Bool = false

    @Flag(
        name: .customLong("with-display"),
        help: "Boot via FirstBootHost (hidden NSWindow + VZVirtualMachineView). Required for Setup-Assistant-pending bundles; implies --skip-ssh-wait."
    )
    var withDisplay: Bool = false

    func run() async throws {
        let bundle = try bundle.load()
        if let existing = VMPidFile.read(bundle), VMPidFile.isAlive(existing) {
            throw VMError(
                "bundle is already booted by PID \(existing) (delete \(bundle.pidFileURL.lastPathComponent) if that's stale)"
            )
        }

        if withDisplay {
            try await runWithDisplay(bundle: bundle)
        } else {
            try await runHeadless(bundle: bundle)
        }
    }

    private func runHeadless(bundle: VMBundle) async throws {
        let host = try await MainActor.run { try VMHost(bundle: bundle) }
        try await host.start()
        try VMPidFile.write(getpid(), to: bundle)
        defer { VMPidFile.clear(bundle) }

        let ip = try await host.waitForIP(timeout: ipTimeout)

        if !skipSSHWait {
            let endpoint = VMSSH.endpoint(bundle: bundle, host: ip)
            Log.info("waiting for SSH (\(endpoint.user)@\(ip):\(endpoint.port))…")
            try await VMSSH.waitForReady(endpoint: endpoint, timeout: sshTimeout)
            Log.info("SSH ready")
        }

        printConnectionBanner(bundle: bundle, ip: ip)

        let signal = await SignalWaiter.waitForTerminationSignal()
        Log.info("received signal \(signal); shutting down")

        do {
            try await host.requestStop()
            try await host.waitForStop(timeout: shutdownTimeout)
            Log.info("VM stopped cleanly")
        } catch {
            Log.info("graceful shutdown failed: \(error.localizedDescription); forcing")
            try? await host.forceStop()
            throw error
        }
    }

    private func runWithDisplay(bundle: VMBundle) async throws {
        let host = try await MainActor.run { try FirstBootHost(bundle: bundle) }
        try await host.start()
        try VMPidFile.write(getpid(), to: bundle)
        defer { VMPidFile.clear(bundle) }

        printFirstBootBanner(bundle: bundle)

        let signal = await SignalWaiter.waitForTerminationSignal()
        Log.info("received signal \(signal); shutting down first-boot VM")

        // Setup-Assistant-pending macOS does NOT respond to ACPI
        // shutdown — graceful shutdown wiring isn't installed until
        // after Setup Assistant completes. We try briefly, then force.
        // Once #11b's keyboard script has gotten past SA, requestStop
        // becomes effective; for now, force-stop is the expected path.
        let gracefulBudget: TimeInterval = 10
        do {
            try await host.requestStop()
            try await host.waitForStop(timeout: gracefulBudget)
            Log.info("first-boot VM stopped cleanly")
        } catch {
            Log.info("guest didn't respond to graceful shutdown in \(Int(gracefulBudget))s (expected for Setup-Assistant-pending bundles); force-stopping")
            do {
                try await host.forceStop()
            } catch {
                Log.info("force-stop also failed: \(error.localizedDescription)")
                throw error
            }
        }
        await MainActor.run { host.close() }
    }

    private func printFirstBootBanner(bundle: VMBundle) {
        let banner = """

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          vz — first-boot (hidden display) running
            \(bundle.url.path)

          The VM is booting with a VZVirtualMachineView attached to a
          hidden NSWindow at (-10000, -10000). Setup Assistant is
          running in the off-screen framebuffer. Phase 11b will drive
          it via scripted NSEvent.postEvent keystrokes; for now, ^C
          stops the VM.
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        """
        FileHandle.standardError.write(Data(banner.utf8))
    }

    private func printConnectionBanner(bundle: VMBundle, ip: String) {
        let user = bundle.config.sshUsername
        let key = bundle.sshPrivateKeyURL.path
        let known = bundle.knownHostsURL.path
        let banner = """

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          vz — VM up at \(ip)

          From another shell:
            vz ssh \(bundle.url.path) -- <cmd>
            vz stop \(bundle.url.path)

          Or directly:
            ssh -i \(key) -o UserKnownHostsFile=\(known) \(user)@\(ip)

          ^C in this shell to stop. PID file: \(bundle.pidFileURL.path)
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        """
        FileHandle.standardError.write(Data(banner.utf8))
    }
}

import ArgumentParser
import Darwin
import Foundation
import PreviewsVMKit

/// Connect to a booted bundle via SSH. The bundle's MAC is looked up in
/// `/var/db/dhcpd_leases`, so we don't need IPC with the `boot` process —
/// any shell with read access to the lease file can reach the guest.
///
/// Usage:
///     previewsvm ssh ./my.bundle                     — interactive shell
///     previewsvm ssh ./my.bundle -- uptime           — exec and print output
///     previewsvm ssh ./my.bundle -- sudo dtrace -ln 'pid$target:::' -p `pgrep XCPreviewAgent`
struct SSHCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "Open a shell or exec a command in the booted bundle.",
        discussion: """
            Anything after `--` is forwarded as the remote command. Without
            `--`, an interactive TTY shell is opened.
            """
    )

    @OptionGroup var bundle: BundleArgument

    @Option(name: .long, help: "Seconds to wait for SSH to respond before giving up.")
    var sshTimeout: Double = 30

    @Argument(
        parsing: .captureForPassthrough,
        help: ArgumentHelp("Remote command (everything after `--`)", visibility: .default)
    )
    var remoteCommand: [String] = []

    func run() async throws {
        let bundle = try bundle.load()
        guard let ip = VMNetwork.ipAddress(forMAC: bundle.config.macAddress) else {
            throw VMError(
                "no DHCP lease for MAC \(bundle.config.macAddress); is `previewsvm boot` running?"
            )
        }
        let endpoint = VMSSH.endpoint(bundle: bundle, host: ip)

        // Short readiness probe so we don't drop the user into ssh that
        // immediately fails with "Connection refused" right after boot.
        if !remoteCommand.isEmpty {
            try await VMSSH.waitForReady(endpoint: endpoint, timeout: sshTimeout)
        }

        let command = remoteCommand.isEmpty ? nil : remoteCommand.joined(separator: " ")
        let exit = try VMSSH.execInteractive(endpoint: endpoint, command: command)
        Darwin.exit(exit)
    }
}

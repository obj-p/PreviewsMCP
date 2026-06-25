import ArgumentParser
import Foundation
import VZKit

/// Create a fresh bundle from an IPSW and run `VZMacOSInstaller` into it.
///
/// State of this command: prep + headless install are implemented. The
/// resulting bundle holds a freshly-installed macOS that hasn't run
/// Setup Assistant yet — `vz boot` works, but you'd see Setup
/// Assistant in the (unattached) framebuffer. First-boot Setup Assistant
/// scripting + SSH provisioning land in follow-ups (#11, #12).
struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Create a fresh bundle from an IPSW and run VZMacOSInstaller into it."
    )

    @Argument(help: ArgumentHelp(
        "Path to the bundle directory to create. Must be empty or non-existent."
    ))
    var path: String

    @Option(
        name: .long,
        help: ArgumentHelp(
            "IPSW source: a local file path, an https:// URL, or omit for `latest`.",
            discussion: "Downloaded IPSWs are cached at ~/.cache/vz/ipsw/."
        )
    )
    var ipsw: String?

    @Option(name: .customLong("cpu-count"), help: "Guest CPU count.")
    var cpuCount: Int = 4

    @Option(name: .customLong("memory-mib"), help: "Guest memory size in MiB.")
    var memoryMiB: UInt64 = 8 * 1024

    @Option(
        name: .customLong("disk-gib"),
        help: "Guest disk size in GiB (sparse — costs ~0 bytes until written)."
    )
    var diskSizeGiB: UInt64 = 64

    @Option(name: .long, help: "Username for the SSH/admin user the provisioning pass will create.")
    var sshUsername: String = "admin"

    @Flag(
        name: .customLong("skip-install"),
        help: "Only prep the bundle directory; skip the VZMacOSInstaller drive."
    )
    var skipInstall: Bool = false

    func run() async throws {
        let bundleURL = resolveBundleURL()
        // Validate the bundle dir before kicking off a potentially-multi-GB
        // IPSW download — fail fast if the target won't accept the result.
        try BundleProvisioner.ensureCreatable(bundleURL: bundleURL)
        let ipswURL = try await IPSWStore.resolve(ipsw)

        let options = BundleProvisioner.Options(
            cpuCount: cpuCount,
            memorySizeBytes: memoryMiB * 1024 * 1024,
            diskSizeBytes: diskSizeGiB * 1024 * 1024 * 1024,
            sshUsername: sshUsername
        )

        let bundle = try await BundleProvisioner.provision(
            bundleURL: bundleURL,
            ipswURL: ipswURL,
            options: options
        )

        if skipInstall {
            printSkippedBanner(bundle: bundle, ipswURL: ipswURL)
            return
        }

        try await Installer.install(bundle: bundle, ipswURL: ipswURL)
        printNextStepBanner(bundle: bundle, ipswURL: ipswURL)
    }

    private func resolveBundleURL() -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(filePath: expanded)
        }
        return URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: expanded)
    }

    private func printNextStepBanner(bundle: VMBundle, ipswURL _: URL) {
        let banner = """

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          macOS installed into \(bundle.url.path)

          The bundle holds a freshly-installed but UNPROVISIONED macOS.
          Setup Assistant has not yet run. `vz boot` will work,
          but the framebuffer (unattached) will be sitting at Setup
          Assistant, and SSH is not yet enabled — so `vz ssh`
          can't reach the guest yet.

          Next steps (not yet implemented):
            • #11 First-boot Setup Assistant driver (keyboard script)
            • #12 Remote Login + SSH key drop
            • #13 base snapshot
            • #14 SIP/AMFI off + Xcode install

          See research/vm/README.md → Roadmap.
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        """
        FileHandle.standardError.write(Data(banner.utf8))
    }

    private func printSkippedBanner(bundle: VMBundle, ipswURL: URL) {
        let banner = """

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Bundle prepped (--skip-install set; disk.img is empty):
            \(bundle.url.path)

          Re-run without --skip-install to drive VZMacOSInstaller against
          \(ipswURL.lastPathComponent).
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        """
        FileHandle.standardError.write(Data(banner.utf8))
    }
}

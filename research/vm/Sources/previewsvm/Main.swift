import AppKit
import ArgumentParser
import Darwin
import Foundation

@main
struct PreviewsVMApp {
    static func main() {
        let command: ParsableCommand
        do {
            command = try PreviewsVMCommand.parseAsRoot()
        } catch {
            PreviewsVMCommand.exit(withError: error)
        }

        if let asyncCmd = command as? any AsyncParsableCommand {
            // Drive AppKit's runloop. The install command needs it for
            // the hidden-window first-boot driver; boot/ssh/stop/status
            // tolerate it (`NSApp.run` is a superset of `dispatchMain`
            // for their purposes). `.accessory` keeps the binary off the
            // Dock — matches PreviewsMCP's `serve` pattern.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            Task {
                do {
                    var mutable = asyncCmd
                    try await mutable.run()
                    Darwin.exit(0)
                } catch {
                    PreviewsVMCommand.exit(withError: error)
                }
            }
            app.run()  // never returns; Task exits the process
        }

        do {
            var mutable = command
            try mutable.run()
        } catch {
            PreviewsVMCommand.exit(withError: error)
        }
    }
}

struct PreviewsVMCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "previewsvm",
        abstract: "Spin up a SIP/AMFI-off macOS VM and connect to it for JIT-spike research.",
        discussion: """
            Wraps Virtualization.framework so the JIT executor research
            (prompts/jit-executor-research.md, W1) has a reproducible,
            disposable macOS VM where dtrace and lldb can attach to
            entitlement-restricted Apple binaries (XCPreviewAgent,
            previewsd, PreviewShellMac).

            Today this CLI operates on an already-installed bundle. The
            `install` subcommand is stubbed; install-from-IPSW lands in
            a follow-up.
            """,
        subcommands: [
            BootCommand.self,
            SSHCommand.self,
            StopCommand.self,
            StatusCommand.self,
            InstallCommand.self,
            SnapshotCommand.self,
            TestKeysCommand.self,
            SetupCommand.self,
            TestVNCCommand.self,
        ],
        defaultSubcommand: StatusCommand.self
    )
}

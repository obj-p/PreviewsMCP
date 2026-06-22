import AppKit
import ArgumentParser
import Darwin
import Foundation

@main
struct VZApp {
    static func main() {
        let command: ParsableCommand
        do {
            command = try VZCommand.parseAsRoot()
        } catch {
            VZCommand.exit(withError: error)
        }

        if let asyncCmd = command as? any AsyncParsableCommand {
            let runAsync = {
                Task {
                    do {
                        var mutable = asyncCmd
                        try await mutable.run()
                        Darwin.exit(0)
                    } catch {
                        VZCommand.exit(withError: error)
                    }
                }
            }
            if command is SSHCommand {
                runAsync()
                dispatchMain()
            } else {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                runAsync()
                app.run()
            }
        }

        do {
            var mutable = command
            try mutable.run()
        } catch {
            VZCommand.exit(withError: error)
        }
    }
}

struct VZCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vz",
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
            RunCommand.self,
        ],
        defaultSubcommand: StatusCommand.self
    )
}

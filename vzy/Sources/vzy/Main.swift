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
                _ = runAsync()
                dispatchMain()
            } else {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                _ = runAsync()
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
        commandName: "vzy",
        abstract: "Provision and drive disposable macOS VMs via Virtualization.framework.",
        discussion: """
        Wraps Virtualization.framework to install, snapshot, provision,
        and run scripts against reproducible macOS guests. Used by the
        devbox and merge-queue toolchains to build self-contained VMs.
        """,
        subcommands: [
            BootCommand.self,
            SSHCommand.self,
            StopCommand.self,
            StatusCommand.self,
            InstallCommand.self,
            SnapshotCommand.self,
            SetupCommand.self,
            RunCommand.self,
        ],
        defaultSubcommand: StatusCommand.self
    )
}

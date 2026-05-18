import ArgumentParser
import Foundation
import PreviewsVMKit

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show bundle state — boot PID, lease, SSH reachability."
    )

    @OptionGroup var bundle: BundleArgument

    @Flag(name: .long, help: "Skip the SSH probe; report only PID + DHCP info.")
    var skipSSHProbe: Bool = false

    func run() async throws {
        let bundle = try bundle.load()
        let pid = VMPidFile.read(bundle)
        let pidAlive = pid.map(VMPidFile.isAlive) ?? false
        let ip = VMNetwork.ipAddress(forMAC: bundle.config.macAddress)

        print("bundle:           \(bundle.url.path)")
        print("config.cpuCount:  \(bundle.config.cpuCount)")
        print("config.memory:    \(bundle.config.memorySizeBytes / 1024 / 1024) MiB")
        print("config.mac:       \(bundle.config.macAddress)")
        print("config.user:      \(bundle.config.sshUsername)")
        switch pid {
        case .some(let p) where pidAlive:
            print("boot PID:         \(p) (alive)")
        case .some(let p):
            print("boot PID:         \(p) (stale — process not running)")
        case .none:
            print("boot PID:         <no pid file>")
        }
        switch ip {
        case .some(let value):
            print("DHCP lease:       \(value)")
        case .none:
            print("DHCP lease:       <none>")
        }

        if !skipSSHProbe, let ip {
            let endpoint = VMSSH.endpoint(bundle: bundle, host: ip)
            do {
                let result = try await VMSSH.exec(endpoint: endpoint, command: "uname -a", timeout: 5)
                if result.exitCode == 0 {
                    let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    print("ssh probe:        ok (\(line))")
                } else {
                    print("ssh probe:        ssh exit \(result.exitCode)")
                }
            } catch {
                print("ssh probe:        \(error.localizedDescription)")
            }
        }
    }
}

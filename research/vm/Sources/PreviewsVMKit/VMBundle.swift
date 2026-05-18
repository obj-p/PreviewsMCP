import Foundation

/// A `VMBundle` is a directory on disk that holds everything needed to run
/// one macOS guest: the disk image, the auxiliary storage (NVRAM), the
/// hardware-model + machine-identifier blobs that come from the IPSW, the
/// MAC address we burn into the NIC so DHCP leases are stable, and the
/// SSH key we use to log in.
///
/// Layout:
///
///     mybundle.bundle/
///     ├── config.json                 — bundle metadata (CPU/memory/MAC/SSH user)
///     ├── disk.img                    — main filesystem image (sparse)
///     ├── aux.img                     — VZMacAuxiliaryStorage (NVRAM)
///     ├── machine-identifier.bin      — VZMacMachineIdentifier dataRepresentation
///     ├── hardware-model.bin          — VZMacHardwareModel dataRepresentation
///     ├── id_ed25519                  — SSH private key (mode 0600)
///     ├── id_ed25519.pub              — SSH public key (provisioned into guest)
///     ├── known_hosts                 — known-hosts file (populated on first SSH)
///     └── running.pid                 — present while a `boot` is alive (PID)
///
/// The first iteration of the harness operates on an existing bundle (one
/// that's already been installed and provisioned). The `install` subcommand
/// stub is where we'll later wire up IPSW → disk creation → first boot →
/// SIP/AMFI dance → SSH provisioning.
public struct VMBundle: Sendable {
    public let url: URL
    public let config: BundleConfig

    public struct BundleConfig: Codable, Sendable {
        public var cpuCount: Int
        public var memorySizeBytes: UInt64
        public var macAddress: String
        public var sshUsername: String
        public var sshKeyName: String

        public init(
            cpuCount: Int,
            memorySizeBytes: UInt64,
            macAddress: String,
            sshUsername: String,
            sshKeyName: String = "id_ed25519"
        ) {
            self.cpuCount = cpuCount
            self.memorySizeBytes = memorySizeBytes
            self.macAddress = macAddress
            self.sshUsername = sshUsername
            self.sshKeyName = sshKeyName
        }
    }

    public init(directory: URL) throws {
        let normalized = directory.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw VMError("bundle does not exist or is not a directory: \(normalized.path)")
        }
        self.url = normalized
        let configURL = normalized.appending(component: "config.json")
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw VMError("could not read \(configURL.lastPathComponent)", underlying: error)
        }
        do {
            self.config = try JSONDecoder().decode(BundleConfig.self, from: data)
        } catch {
            throw VMError("\(configURL.lastPathComponent) is malformed", underlying: error)
        }
    }

    public var configURL: URL { url.appending(component: "config.json") }
    public var diskImageURL: URL { url.appending(component: "disk.img") }
    public var auxStorageURL: URL { url.appending(component: "aux.img") }
    public var machineIdentifierURL: URL { url.appending(component: "machine-identifier.bin") }
    public var hardwareModelURL: URL { url.appending(component: "hardware-model.bin") }
    public var sshPrivateKeyURL: URL { url.appending(component: config.sshKeyName) }
    public var sshPublicKeyURL: URL { url.appending(component: "\(config.sshKeyName).pub") }
    public var knownHostsURL: URL { url.appending(component: "known_hosts") }
    public var pidFileURL: URL { url.appending(component: "running.pid") }

    /// Throws unless every file required to boot an installed bundle is present.
    public func requireRunnable() throws {
        try require(diskImageURL, what: "disk image")
        try require(auxStorageURL, what: "auxiliary storage")
        try require(machineIdentifierURL, what: "machine identifier")
        try require(hardwareModelURL, what: "hardware model")
        try require(sshPrivateKeyURL, what: "SSH private key (config.sshKeyName=\(config.sshKeyName))")
    }

    private func require(_ url: URL, what: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VMError("missing \(what) at \(url.path)")
        }
    }
}

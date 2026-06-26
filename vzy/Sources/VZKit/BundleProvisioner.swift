import Foundation
import Virtualization

/// Creates an empty (pre-install) `VMBundle` on disk from an IPSW.
///
/// "Pre-install" means: every artifact `VMBundle.requireRunnable` checks
/// is present (disk image, aux storage, hardware model, machine identifier,
/// SSH key, config.json), but `disk.img` has no operating system on it
/// yet. The next step — `VZMacOSInstaller` — is what actually populates
/// the disk; that lands in a follow-up.
///
/// This split is intentional: bundle prep is sync, deterministic, and
/// testable without booting a VM, while the installer drive is async,
/// long-running, and needs the VZ runtime. Keeping them in different
/// files keeps the failure modes separable.
public enum BundleProvisioner {
    public struct Options: Sendable {
        public var cpuCount: Int
        public var memorySizeBytes: UInt64
        public var diskSizeBytes: UInt64
        public var sshUsername: String
        public var sshKeyName: String

        public init(
            cpuCount: Int = 4,
            memorySizeBytes: UInt64 = 8 * 1024 * 1024 * 1024,
            diskSizeBytes: UInt64 = 64 * 1024 * 1024 * 1024,
            sshUsername: String = "admin",
            sshKeyName: String = "id_ed25519"
        ) {
            self.cpuCount = cpuCount
            self.memorySizeBytes = memorySizeBytes
            self.diskSizeBytes = diskSizeBytes
            self.sshUsername = sshUsername
            self.sshKeyName = sshKeyName
        }
    }

    /// Check the bundle directory is creatable / empty without doing any
    /// other work. Worth calling before kicking off an IPSW download so a
    /// non-empty bundle dir fails fast.
    public static func ensureCreatable(bundleURL: URL) throws {
        try ensureEmptyDirectory(bundleURL)
    }

    /// Build a fresh bundle at `bundleURL`, drawing platform parameters
    /// from `ipswURL`'s most-featureful supported configuration.
    ///
    /// Refuses to overwrite an existing non-empty bundle dir — the caller
    /// must `rm -rf` first. This is research code; preserving the safety
    /// rail is cheaper than reasoning about partial-overwrite states.
    @MainActor
    public static func provision(
        bundleURL: URL,
        ipswURL: URL,
        options: Options = .init()
    ) async throws -> VMBundle {
        try ensureEmptyDirectory(bundleURL)

        let image: VZMacOSRestoreImage
        do {
            image = try await IPSWStore.loadRestoreImage(at: ipswURL)
        } catch {
            throw VMError("could not parse IPSW at \(ipswURL.path)", underlying: error)
        }
        guard let configRequirements = image.mostFeaturefulSupportedConfiguration else {
            throw VMError("IPSW reports no supported configurations on this host")
        }
        guard configRequirements.hardwareModel.isSupported else {
            throw VMError("IPSW's hardware model is not supported on this host")
        }
        try validate(options: options, against: configRequirements)

        Log.info("provisioning bundle at \(bundleURL.path)")
        Log.info("  macOS \(image.operatingSystemVersion) (\(image.buildVersion))")
        Log
            .info(
                "  cpu=\(options.cpuCount) memory=\(options.memorySizeBytes / 1024 / 1024)MiB disk=\(options.diskSizeBytes / 1024 / 1024 / 1024)GiB"
            )

        let hardwareModelData = configRequirements.hardwareModel.dataRepresentation
        try hardwareModelData.write(to: bundleURL.appending(path: "hardware-model.bin"))

        let machineIdentifier = VZMacMachineIdentifier()
        try machineIdentifier.dataRepresentation.write(
            to: bundleURL.appending(path: "machine-identifier.bin")
        )

        try createDiskImage(
            at: bundleURL.appending(path: "disk.img"),
            sizeBytes: options.diskSizeBytes
        )

        let auxURL = bundleURL.appending(path: "aux.img")
        do {
            _ = try VZMacAuxiliaryStorage(
                creatingStorageAt: auxURL,
                hardwareModel: configRequirements.hardwareModel,
                options: []
            )
        } catch {
            throw VMError("could not create aux.img", underlying: error)
        }

        try generateSSHKeyPair(
            at: bundleURL.appending(path: options.sshKeyName)
        )

        let macAddress = VZMACAddress.randomLocallyAdministered().string
        let config = VMBundle.BundleConfig(
            cpuCount: options.cpuCount,
            memorySizeBytes: options.memorySizeBytes,
            macAddress: macAddress,
            sshUsername: options.sshUsername,
            sshKeyName: options.sshKeyName
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let configData = try encoder.encode(config)
        try configData.write(to: bundleURL.appending(path: "config.json"))

        // VMBundle init re-reads config.json + checks layout. Cheaper than
        // assembling a struct by hand from local state; also exercises
        // the same validation path callers will hit.
        let bundle = try VMBundle(directory: bundleURL)
        Log.info("bundle ready for install — \(bundle.config.macAddress)")
        return bundle
    }

    // MARK: - Internals

    private static func ensureEmptyDirectory(_ url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw VMError("target exists and is not a directory: \(url.path)")
            }
            let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            if !contents.isEmpty {
                throw VMError(
                    "refusing to overwrite non-empty directory: \(url.path) (remove it first)"
                )
            }
        } else {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw VMError("could not create bundle directory at \(url.path)", underlying: error)
            }
        }
    }

    private static func validate(
        options: Options,
        against requirements: VZMacOSConfigurationRequirements
    ) throws {
        if UInt64(options.cpuCount) < UInt64(requirements.minimumSupportedCPUCount) {
            throw VMError(
                "cpuCount=\(options.cpuCount) is below the IPSW's required minimum of \(requirements.minimumSupportedCPUCount)"
            )
        }
        if options.memorySizeBytes < requirements.minimumSupportedMemorySize {
            let minMiB = requirements.minimumSupportedMemorySize / 1024 / 1024
            let gotMiB = options.memorySizeBytes / 1024 / 1024
            throw VMError(
                "memorySizeBytes=\(gotMiB)MiB is below the IPSW's required minimum of \(minMiB)MiB"
            )
        }
    }

    /// Create a sparse disk image. APFS supports holes natively, so a
    /// 64 GiB "disk" costs ~0 bytes until the installer writes into it.
    private static func createDiskImage(at url: URL, sizeBytes: UInt64) throws {
        let fm = FileManager.default
        let path = url.path
        guard fm.createFile(atPath: path, contents: nil) else {
            throw VMError("could not create \(path)")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw VMError("could not open \(path) for writing", underlying: error)
        }
        defer { try? handle.close() }
        do {
            try handle.truncate(atOffset: sizeBytes)
        } catch {
            throw VMError("could not size \(path) to \(sizeBytes) bytes", underlying: error)
        }
    }

    /// Shell out to ssh-keygen. Writing our own ed25519 implementation in
    /// Swift is a meaningful effort for a feature whose result we're going
    /// to hand back to /usr/bin/ssh anyway — easier to use the same tool
    /// on both sides.
    private static func generateSSHKeyPair(at url: URL) throws {
        let path = url.path
        if FileManager.default.fileExists(atPath: path) {
            // The Options.sshKeyName collision case — preserve any existing
            // key the user dropped in, but it's a hard error: we'd otherwise
            // ship inconsistent pub/priv halves.
            throw VMError("SSH key already exists at \(path); refusing to overwrite")
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
        process.arguments = [
            "-t", "ed25519",
            "-f", path,
            "-N", "", // no passphrase
            "-C", "vz@\(url.lastPathComponent)",
            "-q", // quiet
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw VMError("could not spawn ssh-keygen", underlying: error)
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw VMError(
                "ssh-keygen exited \(process.terminationStatus): \(errStr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }
}

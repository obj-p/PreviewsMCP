import Foundation
import Virtualization

/// Builds a `VZVirtualMachineConfiguration` from a `VMBundle`. Touches the
/// VZ API surface only; everything that crosses isolation lives in
/// `VMBundle.BundleConfig` (Sendable) and the file URLs.
///
/// Why @MainActor: `VZVirtualMachineConfiguration` and its sub-objects are
/// not Sendable and aren't safe to touch off-main. We pin every VZ object
/// to the main actor so Swift 6's strict-concurrency checker can see
/// the boundary.
public enum VMConfiguration {
    public struct DirectoryShare: Sendable {
        public let hostURL: URL
        public let readOnly: Bool

        public init(hostURL: URL, readOnly: Bool) {
            self.hostURL = hostURL
            self.readOnly = readOnly
        }
    }

    public static let directoryShareTag = VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag

    public static let macOSAutomountPath = "/Volumes/My Shared Files"

    @MainActor
    public static func build(bundle: VMBundle, share: DirectoryShare? = nil) throws
        -> VZVirtualMachineConfiguration
    {
        try bundle.requireRunnable()

        let config = VZVirtualMachineConfiguration()
        config.cpuCount = bundle.config.cpuCount
        config.memorySize = bundle.config.memorySizeBytes
        config.bootLoader = VZMacOSBootLoader()
        config.platform = try makePlatform(bundle: bundle)
        config.storageDevices = [try makeStorage(bundle: bundle)]
        config.networkDevices = [try makeNetwork(bundle: bundle)]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        if let share {
            config.directorySharingDevices = [makeDirectoryShare(share)]
        }

        // Graphics + keyboard + pointing devices are required even for
        // headless operation. Apple's "Install macOS in a VM" sample
        // includes all three. Empirically, omitting them caused
        // `VZMacOSInstaller` to fail mid-install with `VZErrorCode 10007`
        // + nested MobileRestore error 4014 ("Unexpected device state
        // 'DFU' expected 'RestoreOS'") — the installer couldn't
        // transition the VM out of the firmware-load phase without a
        // display attached. The display can be unobserved (no
        // `VZVirtualMachineView`), so this keeps the CLI window-free
        // for normal boot.
        let display = VZMacGraphicsDisplayConfiguration(
            widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 220)
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [display]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        do {
            try config.validate()
        } catch {
            throw VMError("VZ configuration failed validation", underlying: error)
        }
        return config
    }

    private static func makeDirectoryShare(_ share: DirectoryShare)
        -> VZVirtioFileSystemDeviceConfiguration
    {
        let device = VZVirtioFileSystemDeviceConfiguration(tag: directoryShareTag)
        device.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: share.hostURL, readOnly: share.readOnly))
        return device
    }

    @MainActor
    private static func makePlatform(bundle: VMBundle) throws -> VZMacPlatformConfiguration {
        let platform = VZMacPlatformConfiguration()
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxStorageURL)

        let hwData: Data
        do {
            hwData = try Data(contentsOf: bundle.hardwareModelURL)
        } catch {
            throw VMError("could not read hardware-model.bin", underlying: error)
        }
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hwData) else {
            throw VMError("hardware-model.bin is not a valid VZMacHardwareModel encoding")
        }
        platform.hardwareModel = hardwareModel

        let idData: Data
        do {
            idData = try Data(contentsOf: bundle.machineIdentifierURL)
        } catch {
            throw VMError("could not read machine-identifier.bin", underlying: error)
        }
        guard let identifier = VZMacMachineIdentifier(dataRepresentation: idData) else {
            throw VMError("machine-identifier.bin is not a valid VZMacMachineIdentifier encoding")
        }
        platform.machineIdentifier = identifier
        return platform
    }

    @MainActor
    private static func makeStorage(bundle: VMBundle) throws -> VZStorageDeviceConfiguration {
        let attachment: VZDiskImageStorageDeviceAttachment
        do {
            attachment = try VZDiskImageStorageDeviceAttachment(
                url: bundle.diskImageURL, readOnly: false)
        } catch {
            throw VMError("could not attach disk image", underlying: error)
        }
        return VZVirtioBlockDeviceConfiguration(attachment: attachment)
    }

    @MainActor
    private static func makeNetwork(bundle: VMBundle) throws -> VZNetworkDeviceConfiguration {
        // NAT is the only attachment type that works without admin rights;
        // it relies on macOS's built-in bootpd, which writes leases to
        // /var/db/dhcpd_leases. VMNetwork.swift parses those.
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZNATNetworkDeviceAttachment()
        guard let mac = VZMACAddress(string: bundle.config.macAddress) else {
            throw VMError("config.macAddress is not a valid MAC: \(bundle.config.macAddress)")
        }
        device.macAddress = mac
        return device
    }
}

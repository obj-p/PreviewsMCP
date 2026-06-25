import Foundation
import Virtualization

/// Drives `VZMacOSInstaller` against a prepped bundle. At the end the
/// bundle's `disk.img` contains a freshly-installed macOS that hasn't
/// run Setup Assistant yet. The first-boot Setup Assistant driver lives
/// in its own file (FirstBootDriver — coming in a follow-up).
///
/// The install runs *headless* — no display device, no keyboard.
/// `VZMacOSInstaller` doesn't need them; macOS only requires a display
/// once it boots into Setup Assistant, which is the next phase.
public enum Installer {
    /// Install macOS from `ipswURL` into `bundle`'s `disk.img`. The
    /// bundle must already be prepped (`BundleProvisioner.provision`).
    @MainActor
    public static func install(bundle: VMBundle, ipswURL: URL) async throws {
        try bundle.requireRunnable()

        Log.info("building install-time VM configuration")
        let config = try VMConfiguration.build(bundle: bundle)
        let vm = VZVirtualMachine(configuration: config)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswURL)

        // NSProgress is documented thread-safe. Capturing it lets the
        // polling task observe fractionCompleted off-main without
        // touching the non-Sendable VZMacOSInstaller itself.
        let progress = installer.progress
        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                let percent = Int(progress.fractionCompleted * 100)
                let stage = progress.localizedDescription ?? ""
                if stage.isEmpty {
                    Log.info("install: \(percent)%")
                } else {
                    Log.info("install: \(percent)% — \(stage)")
                }
            }
        }
        defer { progressTask.cancel() }

        Log.info("starting VZMacOSInstaller — this typically takes 15–30 min")
        do {
            try await driveInstall(installer)
        } catch let nsError as NSError where nsError.domain == VZErrorDomain
            && nsError.code == VZError.installationRequiresUpdate.rawValue
        {
            // VZ refuses to install a guest macOS newer than the host. Give a
            // pointed message — the default NSLocalizedFailure leaves the
            // version-mismatch root cause implicit.
            let hostVersion = ProcessInfo.processInfo.operatingSystemVersionString
            throw VMError(
                """
                VZMacOSInstaller rejected the IPSW: it requires a host newer than this one. \
                Host is \(hostVersion). Either update the host to match-or-exceed the guest \
                IPSW's macOS version, or pass --ipsw with an older IPSW (≤ host version)
                """,
                underlying: nsError
            )
        } catch {
            throw VMError("VZMacOSInstaller.install failed", underlying: error)
        }
        Log.info("install finished — bundle disk.img now holds an unprovisioned macOS")
    }

    /// Bridge `VZMacOSInstaller.install(completionHandler:)` (Result-based
    /// completion-handler only) to async/await. The continuation only
    /// carries `Void` / `Error` — both Sendable — so no carrier box is
    /// needed here (unlike `RestoreImageBox` for the load APIs).
    @MainActor
    private static func driveInstall(_ installer: VZMacOSInstaller) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            installer.install { result in
                switch result {
                case .success: cont.resume()
                case let .failure(error): cont.resume(throwing: error)
                }
            }
        }
    }
}

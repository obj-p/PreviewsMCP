import Foundation
import Virtualization

/// IPSW resolution + on-disk cache.
///
/// Apple ships restore images as `.ipsw` files at multi-GB URLs on the
/// CDN. The cache lives at `~/.cache/previewsvm/ipsw/` keyed by the
/// basename of the source URL (Apple includes the build version in the
/// filename, so this is stable enough). Multiple bundles installed from
/// the same IPSW share one cached file.
///
/// Three input shapes resolve to a local IPSW file:
///
///   - **Local path** (`/foo/restore.ipsw`): used verbatim, no download.
///   - **HTTPS URL**: downloaded to the cache, returned.
///   - **`nil`** (no `--ipsw` flag): `VZMacOSRestoreImage.fetchLatestSupported`
///     is consulted, the resulting CDN URL is downloaded.
public enum IPSWStore {
    /// Directory where downloaded IPSWs are cached.
    public static var cacheDirectory: URL {
        let base = (ProcessInfo.processInfo.environment["XDG_CACHE_HOME"]
            .map { URL(filePath: $0) })
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".cache")
        return base.appending(path: "previewsvm/ipsw")
    }

    public enum Source: Sendable {
        case localFile(URL)
        case remoteURL(URL)
        case latestSupported
    }

    /// Resolve `source` to a local IPSW file, downloading + caching if
    /// necessary. Prints periodic progress to stderr.
    public static func resolve(_ source: Source) async throws -> URL {
        switch source {
        case .localFile(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VMError("IPSW does not exist at \(url.path)")
            }
            return url

        case .remoteURL(let url):
            return try await downloadIfNeeded(remote: url)

        case .latestSupported:
            Log.info("looking up latest supported macOS restore image…")
            let image: VZMacOSRestoreImage
            do {
                image = try await fetchLatestRestoreImage()
            } catch {
                throw VMError("VZMacOSRestoreImage.fetchLatestSupported failed", underlying: error)
            }
            Log.info("latest supported: macOS \(image.operatingSystemVersion) (\(image.buildVersion))")
            return try await downloadIfNeeded(remote: image.url)
        }
    }

    /// Bridge `VZMacOSRestoreImage.fetchLatestSupported(completionHandler:)`
    /// (Result-based, completion-handler only) to async/await.
    ///
    /// Why the box: `VZMacOSRestoreImage` is not `Sendable`, so passing it
    /// directly through a `CheckedContinuation` trips Swift 6's
    /// SendingRisksDataRace check. The image is read-only and Apple's
    /// callbacks deliver it exactly once on an internal queue, so wrapping
    /// in an `@unchecked Sendable` carrier is safe — we just unwrap on
    /// the caller's actor.
    private static func fetchLatestRestoreImage() async throws -> VZMacOSRestoreImage {
        let box: RestoreImageBox = try await withCheckedThrowingContinuation { cont in
            VZMacOSRestoreImage.fetchLatestSupported { result in
                switch result {
                case .success(let image): cont.resume(returning: RestoreImageBox(image))
                case .failure(let error): cont.resume(throwing: error)
                }
            }
        }
        return box.image
    }

    /// Bridge `VZMacOSRestoreImage.load(from:completionHandler:)`. Used by
    /// `BundleProvisioner` and any future caller that needs the parsed
    /// restore-image metadata.
    public static func loadRestoreImage(at url: URL) async throws -> VZMacOSRestoreImage {
        let box: RestoreImageBox = try await withCheckedThrowingContinuation { cont in
            VZMacOSRestoreImage.load(from: url) { result in
                switch result {
                case .success(let image): cont.resume(returning: RestoreImageBox(image))
                case .failure(let error): cont.resume(throwing: error)
                }
            }
        }
        return box.image
    }

    /// Convenience: `resolve` from a CLI string. Empty/nil → latest;
    /// `https://…` → remote; anything else → local path.
    public static func resolve(_ flag: String?) async throws -> URL {
        guard let raw = flag, !raw.isEmpty else {
            return try await resolve(.latestSupported)
        }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            guard let url = URL(string: raw) else {
                throw VMError("not a valid URL: \(raw)")
            }
            return try await resolve(.remoteURL(url))
        }
        let expanded = (raw as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(filePath: expanded)
        } else {
            url = URL(filePath: FileManager.default.currentDirectoryPath)
                .appending(path: expanded)
        }
        return try await resolve(.localFile(url))
    }

    private static func downloadIfNeeded(remote: URL) async throws -> URL {
        try FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)
        let destination = cacheDirectory.appending(path: remote.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            Log.info("using cached IPSW at \(destination.path)")
            return destination
        }

        Log.info("downloading IPSW from \(remote.absoluteString)")
        Log.info("  to \(destination.path)")
        Log.info("  (multi-GB; this can take a long time on a slow link)")

        let reporter = DownloadProgressReporter()
        let session = URLSession(
            configuration: .default,
            delegate: reporter,
            delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                reporter.logProgress()
            }
        }
        defer { progressTask.cancel() }

        let temp: URL
        do {
            (temp, _) = try await session.download(from: remote)
        } catch {
            throw VMError("IPSW download failed", underlying: error)
        }

        // URLSession's "temp" file is unlinked when the next download
        // begins, so atomic-move it into the cache before returning.
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            // The temp may sit in /tmp; copy then delete as a fallback
            // in case `moveItem` trips over a cross-volume rename.
            do {
                try FileManager.default.copyItem(at: temp, to: destination)
                try? FileManager.default.removeItem(at: temp)
            } catch {
                throw VMError("could not place IPSW into cache", underlying: error)
            }
        }
        Log.info("download complete: \(destination.path)")
        return destination
    }
}

/// `VZMacOSRestoreImage` is read-only and Apple's APIs deliver it once
/// on an internal queue. Wrapping it lets us pass through a
/// `CheckedContinuation` under Swift 6 strict concurrency.
private final class RestoreImageBox: @unchecked Sendable {
    let image: VZMacOSRestoreImage
    init(_ image: VZMacOSRestoreImage) { self.image = image }
}

/// `URLSessionDownloadDelegate` that records cumulative byte counts.
/// `IPSWStore.downloadIfNeeded` spawns a separate Task that periodically
/// reads this reporter and emits a stderr line.
private final class DownloadProgressReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var bytesWritten: Int64 = 0
    private var totalBytesExpected: Int64 = 0
    private var lastLoggedPercent: Int = -1

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.bytesWritten = totalBytesWritten
        self.totalBytesExpected = totalBytesExpectedToWrite
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // No-op — URLSession.download(from:) handles the temp file for us.
    }

    func logProgress() {
        lock.lock()
        let got = bytesWritten
        let total = totalBytesExpected
        lock.unlock()
        guard total > 0 else {
            if got > 0 {
                Log.info("download in progress (\(got / 1024 / 1024) MiB, total size unknown yet)")
            }
            return
        }
        let percent = Int(Double(got) / Double(total) * 100)
        if percent != lastLoggedPercent {
            lock.lock()
            lastLoggedPercent = percent
            lock.unlock()
            Log.info("download: \(percent)% (\(got / 1024 / 1024) / \(total / 1024 / 1024) MiB)")
        }
    }
}

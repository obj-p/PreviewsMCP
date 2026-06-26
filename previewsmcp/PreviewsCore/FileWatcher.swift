import CoreServices
import Foundation

/// Watches one or more files for changes using FSEvents.
///
/// FSEvents watches directories (not inodes), so atomic-rename saves —
/// NSDocument, Xcode, JetBrains, default-config vim — surface as changes to
/// the same path rather than vanishing into a deleted-inode hole the way a
/// kqueue/`DispatchSource.makeFileSystemObjectSource` watcher would.
///
/// One watch is installed per unique canonical parent directory; the callback
/// fires when any event under those directories matches a watched path.
public final class FileWatcher: @unchecked Sendable {
    private let box: CallbackBox
    private let queue = DispatchQueue(label: "com.previewsmcp.filewatcher")
    private var stream: FSEventStreamRef?

    public convenience init(
        path: String,
        callback: @escaping @Sendable (Set<String>) -> Void
    ) throws {
        try self.init(paths: [path], callback: callback)
    }

    public init(
        paths: [String],
        callback: @escaping @Sendable (Set<String>) -> Void
    ) throws {
        guard !paths.isEmpty else {
            throw FileWatcherError.cannotOpen(path: "<empty>")
        }
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else {
                throw FileWatcherError.cannotOpen(path: path)
            }
        }

        var canonical = Set<String>()
        var parentDirs = Set<String>()
        for path in paths {
            guard let resolved = Self.canonicalize(path) else {
                throw FileWatcherError.cannotOpen(path: path)
            }
            canonical.insert(resolved)
            parentDirs.insert((resolved as NSString).deletingLastPathComponent)
        }

        box = CallbackBox(canonicalPaths: canonical, callback: callback)

        // Hand FSEvents a retained pointer to `box`, not to `self`. The
        // context's `release` callback drops the +1 when the stream is
        // released by `stop()`. The callback trampoline dereferences `box`
        // via unretained — safe because `box`'s lifetime is anchored to
        // the stream itself, independent of `self`.
        var context = FSEventStreamContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        context.info = Unmanaged.passRetained(box).toOpaque()
        context.release = { info in
            guard let info else { return }
            Unmanaged<CallbackBox>.fromOpaque(info).release()
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )

        let callbackTrampoline: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info, numEvents > 0 else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let nsPaths = cfPaths as NSArray
            // One callback per change-event burst, carrying every watched path the burst
            // touched. A coalesced multi-file save (atomic rename of several files within
            // the latency window) delivers them together so the caller can tell a
            // cross-file edit apart from a primary-only one.
            var fired = Set<String>()
            for case let path as String in nsPaths where box.canonicalPaths.contains(path) {
                fired.insert(path)
            }
            if !fired.isEmpty { box.callback(fired) }
        }

        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callbackTrampoline,
                &context,
                Array(parentDirs) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.05,
                flags
            )
        else {
            // FSEventStreamCreate did not take ownership; drop our +1 on box.
            Unmanaged<CallbackBox>.fromOpaque(context.info!).release()
            throw FileWatcherError.cannotOpen(path: paths.first ?? "<unknown>")
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw FileWatcherError.cannotOpen(path: paths.first ?? "<unknown>")
        }
        self.stream = stream
    }

    public func stop() {
        // Drain any in-flight callback on `queue` before tearing down the
        // stream. `FSEventStreamRelease` triggers the context's release
        // callback, dropping the +1 on `box`.
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit {
        stop()
    }

    /// Resolve a path to the canonical form the FSEvents callback reports. A caller
    /// canonicalizes its watched paths once at setup, then compares the fired paths
    /// (already canonical) against them by string equality with no per-fire syscall.
    public static func canonicalPath(_ path: String) -> String? {
        canonicalize(path)
    }

    private static func canonicalize(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Immutable state read by the FSEvents callback trampoline.
///
/// The callback dereferences this via an unretained pointer; the stream's
/// context release callback drops the matching +1 when the stream is
/// released. Decoupling the callback from `FileWatcher` lets the watcher
/// deinit without racing in-flight callbacks against partial destruction.
private final class CallbackBox: @unchecked Sendable {
    let canonicalPaths: Set<String>
    let callback: @Sendable (Set<String>) -> Void

    init(canonicalPaths: Set<String>, callback: @escaping @Sendable (Set<String>) -> Void) {
        self.canonicalPaths = canonicalPaths
        self.callback = callback
    }
}

public enum FileWatcherError: Error, LocalizedError, CustomStringConvertible {
    case cannotOpen(path: String)

    public var description: String {
        switch self {
        case let .cannotOpen(path):
            "Cannot watch file: \(path)"
        }
    }

    public var errorDescription: String? {
        description
    }
}

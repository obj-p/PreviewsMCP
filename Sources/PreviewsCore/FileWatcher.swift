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
    private let userPaths: [String]
    private let canonicalPaths: Set<String>
    private let callback: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.previewsmcp.filewatcher")
    private var stream: FSEventStreamRef?

    public convenience init(
        path: String,
        callback: @escaping @Sendable () -> Void
    ) throws {
        try self.init(paths: [path], callback: callback)
    }

    public init(
        paths: [String],
        callback: @escaping @Sendable () -> Void
    ) throws {
        guard !paths.isEmpty else {
            throw FileWatcherError.cannotOpen(path: "<empty>")
        }
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else {
                throw FileWatcherError.cannotOpen(path: path)
            }
        }

        self.userPaths = paths
        self.callback = callback

        var canonical = Set<String>()
        var parentDirs = Set<String>()
        for path in paths {
            let resolved = Self.canonicalize(path)
            canonical.insert(resolved)
            parentDirs.insert((resolved as NSString).deletingLastPathComponent)
        }
        self.canonicalPaths = canonical

        var context = FSEventStreamContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )

        let callbackTrampoline: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info, numEvents > 0 else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let nsPaths = cfPaths as NSArray
            for case let path as String in nsPaths where watcher.canonicalPaths.contains(path) {
                watcher.callback()
                return
            }
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
            throw FileWatcherError.cannotOpen(path: paths.first ?? "<unknown>")
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        // Drain any in-flight callback on `queue` before tearing down the
        // stream — the callback dereferences `self` via an unretained info
        // pointer, so it must not run after `stop()` returns to a deiniting
        // owner.
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

    private static func canonicalize(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

public enum FileWatcherError: Error, LocalizedError, CustomStringConvertible {
    case cannotOpen(path: String)

    public var description: String {
        switch self {
        case .cannotOpen(let path):
            return "Cannot watch file: \(path)"
        }
    }

    public var errorDescription: String? { description }
}

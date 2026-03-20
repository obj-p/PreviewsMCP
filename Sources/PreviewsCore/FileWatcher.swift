import Foundation

/// Watches one or more files for changes using polling.
/// Checks file modification dates at a regular interval.
public final class FileWatcher: @unchecked Sendable {
    private let filePaths: [String]
    private let callback: @Sendable () -> Void
    private var timer: DispatchSourceTimer?
    private var lastModDates: [String: Date]
    private let queue = DispatchQueue(label: "com.previewsmcp.filewatcher")

    /// Watch a file and call the callback when it's modified.
    /// Polls every `interval` seconds (default: 0.5s).
    public convenience init(
        path: String,
        interval: TimeInterval = 0.5,
        callback: @escaping @Sendable () -> Void
    ) throws {
        try self.init(paths: [path], interval: interval, callback: callback)
    }

    /// Watch multiple files and call the callback when any is modified.
    /// Polls every `interval` seconds (default: 0.5s).
    public init(
        paths: [String],
        interval: TimeInterval = 0.5,
        callback: @escaping @Sendable () -> Void
    ) throws {
        guard let first = paths.first, FileManager.default.fileExists(atPath: first) else {
            throw FileWatcherError.cannotOpen(path: paths.first ?? "<empty>")
        }

        self.filePaths = paths
        self.callback = callback

        var dates: [String: Date] = [:]
        for path in paths {
            dates[path] = Self.modDate(of: path)
        }
        self.lastModDates = dates

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval
        )
        timer.setEventHandler { [weak self] in
            self?.checkForChanges()
        }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit {
        stop()
    }

    private func checkForChanges() {
        for path in filePaths {
            guard let newDate = Self.modDate(of: path) else { continue }
            if newDate != lastModDates[path] {
                lastModDates[path] = newDate
                callback()
                return  // Fire once per poll cycle
            }
        }
    }

    private static func modDate(of path: String) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.modificationDate] as? Date
    }
}

public enum FileWatcherError: Error, CustomStringConvertible {
    case cannotOpen(path: String)

    public var description: String {
        switch self {
        case .cannotOpen(let path):
            return "Cannot watch file: \(path)"
        }
    }
}

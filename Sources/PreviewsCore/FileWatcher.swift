import Foundation

/// Watches a file for changes using polling.
/// Checks the file's modification date at a regular interval.
public final class FileWatcher: @unchecked Sendable {
    private let filePath: String
    private let callback: @Sendable () -> Void
    private var timer: DispatchSourceTimer?
    private var lastModDate: Date?
    private let queue = DispatchQueue(label: "com.previewsmcp.filewatcher")

    /// Watch a file and call the callback when it's modified.
    /// Polls every `interval` seconds (default: 0.5s).
    public init(
        path: String,
        interval: TimeInterval = 0.5,
        callback: @escaping @Sendable () -> Void
    ) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw FileWatcherError.cannotOpen(path: path)
        }

        self.filePath = path
        self.callback = callback
        self.lastModDate = Self.modDate(of: path)

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
        guard let newDate = Self.modDate(of: filePath) else { return }
        guard newDate != lastModDate else { return }
        lastModDate = newDate
        callback()
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

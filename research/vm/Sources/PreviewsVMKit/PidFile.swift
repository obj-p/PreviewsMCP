import Foundation

/// `boot` writes its PID to `<bundle>/running.pid` so `stop`/`status` from
/// another shell can find the foregrounded VM process. Lifecycle:
///
///     boot:    write(pid) → run → defer { clear() }
///     stop:    read() → kill(pid, SIGTERM)
///     status:  read() → kill(pid, 0) → still alive?
public enum VMPidFile {
    public static func write(_ pid: Int32, to bundle: VMBundle) throws {
        do {
            try Data("\(pid)\n".utf8).write(to: bundle.pidFileURL, options: .atomic)
        } catch {
            throw VMError("could not write \(bundle.pidFileURL.path)", underlying: error)
        }
    }

    public static func read(_ bundle: VMBundle) -> Int32? {
        guard let data = try? Data(contentsOf: bundle.pidFileURL),
              let text = String(data: data, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    public static func clear(_ bundle: VMBundle) {
        try? FileManager.default.removeItem(at: bundle.pidFileURL)
    }

    /// `kill(pid, 0)` checks whether the PID is still ours. Returns
    /// `true` if the process exists, `false` if it does not (or if we
    /// can't sense it).
    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }
}

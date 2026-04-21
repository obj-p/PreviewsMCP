import Foundation

/// Thread-safe accumulator for a subprocess pipe's output. `Pipe`'s
/// `readabilityHandler` closure runs on a background queue, so writes must
/// be synchronized for the poll loop in the caller to safely read
/// `contents()` concurrently.
///
/// Used by integration tests that need to assert on streaming stdout/stderr
/// without capturing to end-of-stream (which would require the subprocess to
/// exit first).
final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        text.append(s)
    }

    func contents() -> String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
}

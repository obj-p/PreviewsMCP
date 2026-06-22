import Darwin
import Foundation

/// Bounded ring rotation for the daemon's `serve.log`.
///
/// The daemon writes every diagnostic line to fd 2 (`Log`, `fputs(_, stderr)`,
/// `write(STDERR_FILENO, …)`). Rotating at the file-descriptor level — rename
/// the current log out of the way, open a fresh file, `dup2` it onto the live
/// fd — transparently redirects all of those writers with no call-site change.
///
/// The ring keeps `serve.log` plus `serve.log.1 … serve.log.<keep>`. On each
/// rotation the oldest is dropped and the rest shift up, so both the file count
/// (`keep + 1`) and total disk (~`(keep + 1) * maxBytes`) stay bounded while
/// the `.1 = newest history` convention `previewsmcp logs` relies on is kept.
public enum LogRotation {

    /// Rotate `logURL` if the file behind `fd` has reached `maxBytes`.
    ///
    /// Returns `true` when a rotation happened. Returns `false` (and does
    /// nothing) when `fd` is not a regular file, is under the threshold, or the
    /// reopen fails — in the failure case the live log is rolled back so `fd`
    /// keeps writing to the path the reader tails.
    @discardableResult
    public static func rotateIfNeeded(
        logURL: URL, fd: Int32, maxBytes: Int, keep: Int
    ) -> Bool {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return false }
        // `S_ISREG` is a C function-like macro and is not imported into Swift,
        // so compare the constants directly.
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return false }
        guard st.st_size >= off_t(maxBytes) else { return false }

        let path = logURL.path
        func ring(_ k: Int) -> String { "\(path).\(k)" }

        // Cascade oldest-first so each destination slot is vacated before it is
        // written, never clobbering a file we mean to keep.
        unlink(ring(keep))
        for k in stride(from: keep - 1, through: 1, by: -1) {
            rename(ring(k), ring(k + 1))
        }
        // Never reach the truncating open below unless the live log was first
        // moved aside — otherwise a failed move would let O_TRUNC wipe it.
        guard rename(path, ring(1)) == 0 else { return false }

        let newfd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard newfd >= 0 else {
            rename(ring(1), path)
            return false
        }
        if newfd != fd {
            guard dup2(newfd, fd) >= 0 else {
                close(newfd)
                rename(ring(1), path)
                return false
            }
            close(newfd)
        }
        return true
    }
}

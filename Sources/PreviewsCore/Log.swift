import Foundation

/// Diagnostic log for daemon, MCP server, and preview-pipeline internals.
///
/// Writes to stderr — visible in `~/.previewsmcp/serve.log` (the daemon's
/// stderr redirect, surfaced by `previewsmcp logs`) and in
/// `MCPTestServer`'s per-instance stderr capture files for CI dumps.
/// `PreviewsMCPApp.main` configures stderr unbuffered (`setvbuf` `_IONBF`)
/// at process entry, so writes here reach disk immediately even if the
/// process is later SIGKILL'd — important for diagnosing wedged
/// subprocesses where buffered output would otherwise be lost.
///
/// Three levels, intentionally lightweight:
/// - ``info(_:)`` — stage markers, progress, normal operational output.
///   No level prefix; preserves the existing serve.log content that
///   consumers already grep against.
/// - ``warn(_:)`` — recoverable conditions worth flagging (retries,
///   fallbacks, slow paths). Prefixed `WARN:` so they stand out in
///   mixed log output.
/// - ``error(_:)`` — hard failures the caller surfaces up. Prefixed
///   `ERROR:`.
///
/// Every line is prefixed with a local wall-clock `[HH:MM:SS.mmm] `
/// stamp so post-mortem analysis of `serve.log` after a CI hang can
/// order interleaved subprocess output and correlate stage markers
/// (e.g. `preview_start/ios:`) against CI step timestamps. The prefix
/// is fixed-width; line-anchored greps should match `^\[[^\]]+\] `
/// before the message body.
///
/// This is a diagnostic surface, not a structured logging framework. If
/// you need structured fields, embed them in the message (`"…
/// attempt=2/3 udid=AB12…"`) so they stay greppable. If we ever need
/// real filtering or routing we can swap the body for `swift-log` or
/// `os.Logger` without changing call sites.
public enum Log {
    public static func info(_ message: String) {
        write(message)
    }

    public static func warn(_ message: String) {
        write("WARN: \(message)")
    }

    public static func error(_ message: String) {
        write("ERROR: \(message)")
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func write(_ line: String) {
        let stamp = timestampFormatter.string(from: Date())
        let data = Data("[\(stamp)] \(line)\n".utf8)
        try? FileHandle.standardError.write(contentsOf: data)
    }
}

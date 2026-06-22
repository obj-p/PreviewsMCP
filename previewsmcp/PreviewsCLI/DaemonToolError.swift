import Foundation

/// Shared error type for CLI commands that forward to an MCP tool in
/// the daemon. Carries the text the daemon returned (whether in an
/// `isError: true` response, a missing session sentinel, or a protocol
/// violation) so the user sees it verbatim instead of a generic
/// "command failed".
///
/// Commands with additional failure modes beyond "the daemon said no"
/// (e.g. `SnapshotCommand`'s invalid-base64 branch) keep their own
/// error types and route their daemon-sourced cases through this one.
enum DaemonToolError: Error, CustomStringConvertible {
    case daemonError(String)

    var description: String {
        switch self {
        case .daemonError(let text): return text
        }
    }
}

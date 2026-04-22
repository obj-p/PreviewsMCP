import Foundation

/// Readonly view of the environment variables the terminal-image code needs.
/// Abstracted into a protocol so tests can drive capability detection with
/// deterministic input rather than mutating the real process environment.
protocol TerminalEnvironment: Sendable {
    var term: String? { get }
    var termProgram: String? { get }
    var lcTerminal: String? { get }
    var kittyWindowID: String? { get }
    var tmux: String? { get }
    var previewsmcpInline: String? { get }
}

struct ProcessTerminalEnvironment: TerminalEnvironment {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    var term: String? { env["TERM"] }
    var termProgram: String? { env["TERM_PROGRAM"] }
    var lcTerminal: String? { env["LC_TERMINAL"] }
    var kittyWindowID: String? { env["KITTY_WINDOW_ID"] }
    var tmux: String? { env["TMUX"] }
    var previewsmcpInline: String? { env["PREVIEWSMCP_INLINE"] }
}

struct MockTerminalEnvironment: TerminalEnvironment {
    var term: String?
    var termProgram: String?
    var lcTerminal: String?
    var kittyWindowID: String?
    var tmux: String?
    var previewsmcpInline: String?
}

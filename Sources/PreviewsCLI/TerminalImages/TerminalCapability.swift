import Foundation

enum TerminalCapability: Sendable, Equatable {
    /// Outer terminal speaks the iTerm2 inline-image protocol (OSC 1337).
    /// Covers iTerm2, WezTerm, and Ghostty — all of which accept the same
    /// encoding.
    case iTerm2
    /// Terminal is known but v1 has no encoder for it. Treat as unsupported
    /// at the render call site; kept as its own case so future protocol
    /// support slots in without changing detection rules.
    case kittyOnly
    /// No inline-image support detected.
    case unsupported

    var supportsInlineV1: Bool { self == .iTerm2 }
}

enum TmuxPassthroughState: Sendable, Equatable {
    case on
    case off
    case unknown
}

/// Seam for the `tmux show-options` call used during capability detection.
protocol TmuxProbe: Sendable {
    func allowPassthrough() -> TmuxPassthroughState
}

/// Shells out to `tmux show-options -gv allow-passthrough`. Accepts both
/// `on` and `all` (tmux ≥ 3.3) as enabled; anything else is `off`.
/// Returns `.unknown` if the command fails — callers then treat it
/// conservatively as "do not emit".
struct ProcessTmuxProbe: TmuxProbe {
    func allowPassthrough() -> TmuxPassthroughState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "show-options", "-gv", "allow-passthrough"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .unknown
        }
        guard process.terminationStatus == 0 else { return .unknown }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch value {
        case "on", "all": return .on
        case "off", "": return .off
        default: return .unknown
        }
    }
}

struct CapabilityDecision: Sendable, Equatable {
    let capability: TerminalCapability
    let needsTmuxWrap: Bool
    /// Non-nil when we intentionally suppressed inline output but want to
    /// explain why on stderr (e.g. tmux passthrough is off).
    let hint: String?
}

enum TerminalCapabilityDetector {
    /// Surfaced on stderr when a user is inside tmux with a supported outer
    /// terminal but `allow-passthrough` is off, so they know why their image
    /// didn't render and how to fix it.
    static let tmuxPassthroughOffHint =
        "note: running inside tmux; enable with `tmux set -g allow-passthrough on`"

    /// Surfaced when `--inline always` forces output on a terminal we can't
    /// classify as supporting iTerm2 protocol — the bytes will show as
    /// garbage on Terminal.app or Alacritty, but at least the user knows why.
    static let forcedOnUnsupportedHint =
        "note: emitting inline image on an unrecognized terminal because --inline always"

    static func detect(
        env: TerminalEnvironment,
        tmuxProbe: TmuxProbe = ProcessTmuxProbe()
    ) -> CapabilityDecision {
        let outer = classifyOuterTerminal(env: env)

        guard env.tmux != nil else {
            return CapabilityDecision(capability: outer, needsTmuxWrap: false, hint: nil)
        }

        // Inside tmux. If the outer terminal can't render, wrapping won't
        // help — skip the probe entirely.
        guard outer.supportsInlineV1 else {
            return CapabilityDecision(capability: .unsupported, needsTmuxWrap: false, hint: nil)
        }

        switch tmuxProbe.allowPassthrough() {
        case .on:
            return CapabilityDecision(capability: outer, needsTmuxWrap: true, hint: nil)
        case .off:
            return CapabilityDecision(
                capability: .unsupported,
                needsTmuxWrap: false,
                hint: tmuxPassthroughOffHint
            )
        case .unknown:
            return CapabilityDecision(capability: .unsupported, needsTmuxWrap: false, hint: nil)
        }
    }

    private static func classifyOuterTerminal(env: TerminalEnvironment) -> TerminalCapability {
        // iTerm2 protocol is accepted by iTerm.app, WezTerm, and Ghostty.
        if env.termProgram == "iTerm.app"
            || env.termProgram == "WezTerm"
            || env.termProgram == "ghostty"
            || env.lcTerminal == "iTerm2"
        {
            return .iTerm2
        }
        if env.term == "xterm-kitty" || env.kittyWindowID != nil {
            return .kittyOnly
        }
        return .unsupported
    }
}

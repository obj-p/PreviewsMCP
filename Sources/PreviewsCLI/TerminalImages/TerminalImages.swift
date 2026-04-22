import ArgumentParser
import Foundation

enum InlineMode: String, Sendable, Equatable, CaseIterable, ExpressibleByArgument {
    case auto, always, never
}

enum InlineDecision: Sendable, Equatable {
    /// Emit these bytes to stdout (already protocol-framed and, if needed,
    /// tmux-wrapped). Caller is responsible for adding a trailing newline
    /// before printing the path.
    case emit(Data)
    /// Skip inline output. `hint` is a short stderr message to surface, if any.
    case skip(hint: String?)
}

/// Pure decision+encoding function with no I/O. The caller injects whether
/// stdout is a TTY and the environment — keeps the unit tests deterministic
/// and runnable without a real terminal.
enum TerminalImages {
    static func renderInline(
        imageData: Data,
        mode: InlineMode,
        jsonOutput: Bool,
        stdoutIsTTY: Bool,
        env: TerminalEnvironment = ProcessTerminalEnvironment(),
        tmuxProbe: TmuxProbe = ProcessTmuxProbe()
    ) -> InlineDecision {
        if jsonOutput { return .skip(hint: nil) }

        let effectiveMode = resolveMode(mode: mode, env: env)

        switch effectiveMode {
        case .never:
            return .skip(hint: nil)
        case .auto where !stdoutIsTTY:
            return .skip(hint: nil)
        case .auto, .always:
            break
        }

        let decision = TerminalCapabilityDetector.detect(env: env, tmuxProbe: tmuxProbe)

        if decision.capability.supportsInlineV1 || effectiveMode == .always {
            return .emit(encode(imageData, wrap: decision.needsTmuxWrap))
        }
        return .skip(hint: decision.hint)
    }

    private static func encode(_ imageData: Data, wrap: Bool) -> Data {
        let downscaled = DownscaleCG.downscaleIfNeeded(imageData)
        let encoded = ITerm2Encoder.encode(imageData: downscaled)
        return wrap ? TmuxPassthrough.wrap(encoded) : encoded
    }

    /// `PREVIEWSMCP_INLINE` lets users pin the mode without touching the
    /// flag every invocation. The flag still wins when set to a non-default
    /// value — only `auto` defers to the env var.
    private static func resolveMode(mode: InlineMode, env: TerminalEnvironment) -> InlineMode {
        guard mode == .auto else { return mode }
        switch env.previewsmcpInline?.lowercased() {
        case "0", "false", "never": return .never
        case "1", "true", "always": return .always
        case "auto", "", nil: return .auto
        default: return .auto
        }
    }
}

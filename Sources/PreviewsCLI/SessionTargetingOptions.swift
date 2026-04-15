import ArgumentParser

/// Shared `--session` / `--file` flags for commands that operate on a
/// running preview session (`configure`, `switch`, `elements`, `touch`,
/// `stop`, `variants`).
///
/// Resolution rules (enforced by `SessionResolver`):
///   * `--session <uuid>` wins outright.
///   * `--file <path>` selects the sole session whose source file matches.
///   * Neither flag: use the sole running session when unambiguous.
struct SessionTargetingOptions: ParsableArguments {
    @Option(name: .long, help: "Target a specific running session by UUID")
    var session: String?

    @Option(name: .long, help: "Resolve session by source file path")
    var file: String?
}

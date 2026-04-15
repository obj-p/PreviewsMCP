import ArgumentParser
import Foundation
import MCP
import PreviewsCore

/// Change rendering traits on a live preview session.
///
/// Forwards to the daemon's `preview_configure` MCP tool. The daemon
/// triggers a recompile on the affected session (which resets `@State`).
///
/// Session targeting follows the same rules as `snapshot`:
/// `--session <id>` > `--file <path>` > sole-running session. Unlike
/// `snapshot`, there's no ephemeral fallback — configuring a non-existent
/// session is an error.
///
/// Pass an empty string to clear a trait (e.g., `--locale ""` to remove
/// an earlier locale override).
struct ConfigureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "configure",
        abstract: "Change rendering traits on a running preview session",
        discussion: """
            Targets the session using the same resolution rules as
            `snapshot`: pass --session for a specific session, --file to
            look up by source path, or no flag when exactly one session
            is running.

            Traits apply cumulatively — unspecified traits keep their
            current values. Pass an empty string to clear a trait.

            Note: dynamicTypeSize only has a visible effect on iOS
            simulator — macOS does not scale fonts in response to this
            modifier.
            """
    )

    @Option(name: .long, help: "Target a specific running session by UUID")
    var session: String?

    @Option(name: .long, help: "Resolve session by source file path")
    var file: String?

    @Option(name: .long, help: "Color scheme: 'light' or 'dark' (empty to clear)")
    var colorScheme: String?

    @Option(name: .long, help: "Dynamic Type size, e.g., 'large' or 'accessibility3' (empty to clear)")
    var dynamicTypeSize: String?

    @Option(name: .long, help: "BCP 47 locale identifier (e.g., 'en', 'ar', 'ja-JP') (empty to clear)")
    var locale: String?

    @Option(name: .long, help: "Layout direction: 'leftToRight' or 'rightToLeft' (empty to clear)")
    var layoutDirection: String?

    @Option(name: .long, help: "Legibility weight: 'regular' or 'bold' (empty to clear)")
    var legibilityWeight: String?

    mutating func run() async throws {
        // Validate traits locally so bad values fail before touching the daemon.
        // Empty strings are allowed here (they mean "clear this trait") and are
        // forwarded to the daemon, which also accepts them as the clear signal.
        if !anyTraitSpecified {
            throw ValidationError(
                "No traits specified. Pass at least one of "
                    + "--color-scheme / --dynamic-type-size / --locale / "
                    + "--layout-direction / --legibility-weight."
            )
        }

        try validateTraitValues()

        try await DaemonClient.withDaemonClient(name: "previewsmcp-configure") { client in
            let resolution = try await SessionResolver.resolve(
                session: session,
                file: file,
                client: client
            )

            guard case .found(let sessionID) = resolution else {
                throw ValidationError(
                    "No session found to configure. Start one with "
                        + "`previewsmcp run <file> --detach` or pass an explicit "
                        + "--session <uuid>."
                )
            }

            var args: [String: Value] = ["sessionID": .string(sessionID)]
            if let colorScheme { args["colorScheme"] = .string(colorScheme) }
            if let dynamicTypeSize { args["dynamicTypeSize"] = .string(dynamicTypeSize) }
            if let locale { args["locale"] = .string(locale) }
            if let layoutDirection { args["layoutDirection"] = .string(layoutDirection) }
            if let legibilityWeight { args["legibilityWeight"] = .string(legibilityWeight) }

            let response = try await client.callTool(
                name: "preview_configure", arguments: args
            )
            if response.isError == true {
                let text = response.content.joinedText()
                throw DaemonToolError.daemonError(text)
            }

            // Surface the daemon's response (typically a summary of what
            // changed) to the user.
            let text = response.content.joinedText()
            if !text.isEmpty { fputs("\(text)\n", stderr) }
        }
    }

    // MARK: - Helpers

    private var anyTraitSpecified: Bool {
        colorScheme != nil || dynamicTypeSize != nil || locale != nil
            || layoutDirection != nil || legibilityWeight != nil
    }

    /// Validate trait values client-side. Matches the daemon's validation
    /// so the user gets a clear error before the RPC round-trip.
    /// Empty strings are the "clear" signal and are always valid.
    private func validateTraitValues() throws {
        do {
            _ = try PreviewTraits.validated(
                colorScheme: nonEmpty(colorScheme),
                dynamicTypeSize: nonEmpty(dynamicTypeSize),
                locale: nonEmpty(locale),
                layoutDirection: nonEmpty(layoutDirection),
                legibilityWeight: nonEmpty(legibilityWeight)
            )
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }

    /// Treat empty strings as nil for validation purposes — the daemon
    /// uses them as the "clear this trait" signal, and PreviewTraits.validated
    /// would reject them as invalid values.
    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

}


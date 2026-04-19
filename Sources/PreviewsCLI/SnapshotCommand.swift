import ArgumentParser
import Foundation
import MCP
import PreviewsCore
import PreviewsEngine

/// Capture a screenshot of a preview.
///
/// Magical resolution (per spec):
///   * `--session <id>` — snapshot that specific session.
///   * `--file <path>` or positional file — if an active session exists for
///     that source file, snapshot it; otherwise create an ephemeral session,
///     capture, and tear it down.
///   * No flags — if exactly one session is running, snapshot it.
///
/// When snapshotting an *existing* session, trait flags (`--color-scheme`
/// etc.) are ignored because they'd mutate the live session. We warn the
/// user rather than silently dropping them. Ephemeral snapshots use the
/// trait flags normally.
struct SnapshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Compile a SwiftUI preview and save a screenshot",
        discussion: """
            Reuses an existing preview session if one is running for the
            target file (or if you pass --session). Otherwise starts an
            ephemeral session in the daemon, captures, and cleans up.

            Uses the `previewsmcp` daemon — it will be auto-started if not
            already running.
            """
    )

    @Argument(help: "Path to Swift source file containing #Preview")
    var file: String?

    @Option(name: .shortAndLong, help: "Output image file path (.jpg or .png)")
    var output: String = "preview.jpg"

    @Option(
        name: .long,
        help: "Target a specific running session by UUID instead of resolving by file"
    )
    var session: String?

    @Option(
        name: .long,
        help: "JPEG quality 0.0–1.0 (default from config or 0.85). 1.0 produces PNG."
    )
    var quality: Double?

    @Option(name: .long, help: "Which preview to snapshot (0-based index)")
    var preview: Int = 0

    @Option(name: .long, help: "Window width (new session only; ignored when reusing a live session)")
    var width: Int = 400

    @Option(name: .long, help: "Window height (new session only; ignored when reusing a live session)")
    var height: Int = 600

    @Option(name: .long, help: "Target platform: 'macos' or 'ios' (auto-detected if omitted)")
    var platform: CLIPlatform?

    @Option(name: .long, help: "Project root path (auto-detected if omitted)")
    var project: String?

    @Option(
        name: .long,
        help: "Xcode scheme name (only for .xcodeproj / .xcworkspace projects with multiple schemes)"
    )
    var scheme: String?

    @Option(name: .long, help: "Simulator device UDID (for ios; auto-selects if omitted)")
    var device: String?

    @Option(
        name: .long, help: "Color scheme: 'light' or 'dark' (new session only; ignored when reusing a live session)")
    var colorScheme: String?

    @Option(name: .long, help: "Dynamic Type size (e.g., 'large', 'accessibility3')")
    var dynamicTypeSize: String?

    @Option(name: .long, help: "Locale identifier (e.g., 'en', 'ar', 'ja-JP')")
    var locale: String?

    @Option(name: .long, help: "Layout direction: 'leftToRight' or 'rightToLeft'")
    var layoutDirection: String?

    @Option(name: .long, help: "Legibility weight: 'regular' or 'bold'")
    var legibilityWeight: String?

    @Option(name: .long, help: "Path to .previewsmcp.json config file (auto-discovered if omitted)")
    var config: String?

    @Flag(
        name: .long,
        help: "Emit a JSON document (sessionID, outputPath, format, bytes) on stdout instead of the bare path"
    )
    var json: Bool = false

    mutating func run() async throws {
        // Validate traits locally so bad flags fail before hitting the daemon.
        do {
            _ = try PreviewTraits.validated(
                colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize,
                locale: locale, layoutDirection: layoutDirection,
                legibilityWeight: legibilityWeight
            )
        } catch {
            throw ValidationError(error.localizedDescription)
        }

        // Resolve file argument — required unless the user passes --session
        // and there's exactly one match (unambiguous).
        if file == nil && session == nil {
            throw ValidationError(
                "Missing file argument. Pass a path or --session <uuid>."
            )
        }

        if let file {
            let fileURL = URL(fileURLWithPath: file).standardizedFileURL
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ValidationError("File not found: \(file)")
            }
        }

        try await DaemonClient.withDaemonClient(name: "previewsmcp-snapshot") { client in
            let resolution = try await SessionResolver.resolve(
                session: session,
                file: file,
                client: client
            )

            switch resolution {
            case .found(let sessionID):
                try await snapshotExisting(sessionID: sessionID, client: client)
            case .notFound:
                guard let file else {
                    throw ValidationError(
                        "Session \(session ?? "?") not found. "
                            + "Pass a file path to create a new ephemeral session."
                    )
                }
                try await snapshotEphemeral(file: file, client: client)
            }
        }
    }

    // MARK: - Execution paths

    /// Snapshot a session that's already running. Trait flags are ignored;
    /// we use whatever traits the session was configured with.
    private func snapshotExisting(sessionID: String, client: Client) async throws {
        if hasTraitFlags {
            fputs(
                "note: trait flags (--color-scheme / --dynamic-type-size / "
                    + "--locale / --layout-direction / --legibility-weight) are "
                    + "ignored when snapshotting an existing session; use "
                    + "`previewsmcp configure` to change traits.\n",
                stderr
            )
        }

        var args: [String: Value] = ["sessionID": .string(sessionID)]
        args["quality"] = .double(resolvedQuality())

        let response = try await client.callTool(name: "preview_snapshot", arguments: args)
        try handleSnapshotResponse(response, sessionID: sessionID)
    }

    /// Pick the quality value to request from the daemon.
    ///
    /// - Explicit `--quality` wins.
    /// - Otherwise infer from the output file extension: `.png` → 1.0 (PNG);
    ///   `.jpg`/`.jpeg` → 0.85 default (JPEG). The daemon uses `quality >= 1.0`
    ///   as its PNG trigger.
    /// - Unknown extensions fall through to 0.85 (JPEG).
    private func resolvedQuality() -> Double {
        if let quality { return quality }
        let ext = (output as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return 1.0
        case "jpg", "jpeg": return 0.85
        default: return 0.85
        }
    }

    /// Create an ephemeral session for the target file, capture, tear down.
    /// Trait flags are applied at start.
    private func snapshotEphemeral(file: String, client: Client) async throws {
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        let configResult = loadProjectConfig(explicit: config, fileURL: fileURL)
        let resolvedPlatform = Self.resolvePlatform(
            explicit: platform,
            config: configResult?.config,
            project: project,
            fileURL: fileURL
        )

        var startArgs: [String: Value] = [
            "filePath": .string(fileURL.path),
            "previewIndex": .int(preview),
            "width": .int(width),
            "height": .int(height),
            // Render off-screen — we only want the pixels, not a visible window.
            "headless": .bool(true),
            // Always resolve platform client-side so the daemon never has to
            // run `swift package describe`. On xcodeproj/xcworkspace trees the
            // daemon's inferredPlatform would otherwise walk up to the repo
            // root and hang resolving the main package.
            "platform": .string(resolvedPlatform.rawValue),
        ]
        if let project { startArgs["projectPath"] = .string(project) }
        if let scheme { startArgs["scheme"] = .string(scheme) }
        if let device { startArgs["deviceUDID"] = .string(device) }
        if let colorScheme { startArgs["colorScheme"] = .string(colorScheme) }
        if let dynamicTypeSize { startArgs["dynamicTypeSize"] = .string(dynamicTypeSize) }
        if let locale { startArgs["locale"] = .string(locale) }
        if let layoutDirection { startArgs["layoutDirection"] = .string(layoutDirection) }
        if let legibilityWeight { startArgs["legibilityWeight"] = .string(legibilityWeight) }
        if let config { startArgs["config"] = .string(config) }

        let startResponse = try await client.callToolStructured(
            name: "preview_start", arguments: startArgs
        )
        if startResponse.isError == true {
            let text = startResponse.content.joinedText()
            throw DaemonToolError.daemonError("Failed to start preview: \(text)")
        }

        guard let structured = startResponse.structuredContent else {
            throw DaemonToolError.daemonError(
                "preview_start response missing structuredContent"
            )
        }
        let sessionID =
            try structured
            .decode(DaemonProtocol.PreviewStartResult.self).sessionID

        var snapshotArgs: [String: Value] = ["sessionID": .string(sessionID)]
        snapshotArgs["quality"] = .double(resolvedQuality())

        // Await the stop so the ephemeral session is actually torn down
        // before this command exits. A fire-and-forget `Task` wouldn't
        // complete in time, leaving an orphan session in the daemon that
        // future snapshots of the same file would ambiguously match.
        do {
            let snapResponse = try await client.callTool(
                name: "preview_snapshot", arguments: snapshotArgs
            )
            await stopEphemeralSession(sessionID: sessionID, client: client)
            try handleSnapshotResponse(snapResponse, sessionID: sessionID)
        } catch {
            // Best-effort cleanup if the snapshot call itself threw.
            await stopEphemeralSession(sessionID: sessionID, client: client)
            throw error
        }
    }

    /// Tear down an ephemeral session. Best-effort — logs a warning if the
    /// stop RPC fails so the session leak is visible instead of silent.
    /// The session would still be cleaned up when the daemon exits, but a
    /// long-lived daemon with many leaked sessions could confuse future
    /// snapshot reuse.
    private func stopEphemeralSession(sessionID: String, client: Client) async {
        do {
            _ = try await client.callTool(
                name: "preview_stop",
                arguments: ["sessionID": .string(sessionID)]
            )
        } catch {
            fputs(
                "warning: failed to stop ephemeral session \(sessionID): \(error)\n",
                stderr
            )
        }
    }

    // MARK: - Helpers

    private var hasTraitFlags: Bool {
        colorScheme != nil || dynamicTypeSize != nil || locale != nil
            || layoutDirection != nil || legibilityWeight != nil
    }

    /// Pick the target platform client-side without hitting the daemon.
    /// Order: explicit flag → config file → SPM-inferred (only when a project
    /// flag doesn't point at an xcodeproj/xcworkspace) → macOS default.
    ///
    /// Skipping SPM-inference for xcodeproj/xcworkspace projects avoids a
    /// previously-observed hang: `SPMBuildSystem.inferredPlatform` walks up
    /// looking for Package.swift and falls through to the *repo* Package.swift
    /// on xcodeproj sources, then runs `swift package describe` there. For
    /// unrelated reasons that subprocess can hang indefinitely on loaded
    /// machines. We don't need it anyway — xcodeproj/xcworkspace projects
    /// aren't SPM packages.
    static func resolvePlatform(
        explicit: CLIPlatform?,
        config: ProjectConfig?,
        project: String?,
        fileURL: URL
    ) -> CLIPlatform {
        if let explicit { return explicit }
        if let cp = config?.platform { return cp == "ios" ? .ios : .macos }
        let isXcodeLike =
            project.map {
                $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace")
            } ?? false
        if !isXcodeLike, SPMBuildSystem.inferredPlatform(for: fileURL) == .iOS {
            return .ios
        }
        return .macos
    }

    /// Write the image returned in the snapshot response to the output path.
    /// Prints either a bare path or a JSON document (when `--json` is set) to
    /// stdout on success.
    private func handleSnapshotResponse(
        _ response: (content: [Tool.Content], isError: Bool?),
        sessionID: String
    ) throws {
        if response.isError == true {
            let text = response.content.joinedText()
            throw DaemonToolError.daemonError("snapshot failed: \(text)")
        }

        for item in response.content {
            if case .image(let base64, let mimeType, _) = item {
                guard let data = Data(base64Encoded: base64) else {
                    throw SnapshotCommandError.invalidImageData
                }
                let outputURL = URL(fileURLWithPath: output)
                try data.write(to: outputURL)
                if json {
                    try emitJSON(
                        SnapshotJSONOutput(
                            sessionID: sessionID,
                            outputPath: outputURL.path,
                            format: format(for: mimeType),
                            bytes: data.count
                        )
                    )
                } else {
                    print(outputURL.path)
                }
                return
            }
        }
        throw SnapshotCommandError.noImageContent(response.content.joinedText())
    }

    private func format(for mimeType: String) -> String {
        switch mimeType {
        case "image/png": return "png"
        case "image/jpeg": return "jpeg"
        default: return mimeType
        }
    }
}

/// `--json` mode output for snapshot. Synthesized client-side; the daemon's
/// `preview_snapshot` tool does not return a structuredContent payload
/// (its "result" is the image bytes, already carried on the content array).
struct SnapshotJSONOutput: Encodable {
    let sessionID: String
    let outputPath: String
    let format: String
    let bytes: Int

}

enum SnapshotCommandError: Error, CustomStringConvertible {
    case invalidImageData
    case noImageContent(String)

    var description: String {
        switch self {
        case .invalidImageData: return "daemon returned invalid (non-base64) image data"
        case .noImageContent(let text):
            return "daemon response contained no image content: \(text)"
        }
    }
}

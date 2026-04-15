import ArgumentParser
import Foundation
import MCP
import PreviewsCore

/// Capture multiple snapshots of a SwiftUI preview under different trait
/// configurations by delegating to the daemon's `preview_variants` MCP
/// tool.
///
/// Magical resolution (matches `snapshot`):
///   * `--session <id>` — use that specific session.
///   * positional file — reuse an existing session for that file, or
///     spin up an ephemeral one for the capture.
///   * no flags — use the sole running session when unambiguous.
///
/// Exit codes:
///   0 — all variants captured
///   1 — partial failure (some variants captured, others failed) or
///       setup / validation error
///   2 — total failure (every variant failed)
struct VariantsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "variants",
        abstract:
            "Capture multiple snapshots of a SwiftUI preview under different trait configurations",
        discussion: """
            Reuses an existing preview session if one is running for the
            target file (or if you pass --session). Otherwise starts an
            ephemeral session, captures every variant, and cleans up.

            Each --variant is either a preset name (light, dark,
            xSmall…accessibility5, rtl, ltr, boldText) or a JSON object
            string with trait fields (colorScheme, dynamicTypeSize,
            locale, layoutDirection, legibilityWeight) and an optional
            label that determines the output filename.
            """
    )

    @Argument(help: "Path to Swift source file containing #Preview")
    var file: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "A trait variant to capture. Repeat for multiple variants.",
            discussion: """
                Either a preset name (light, dark, xSmall…accessibility5, rtl, ltr, boldText) or a JSON object \
                string with trait fields (colorScheme, dynamicTypeSize, locale, layoutDirection, legibilityWeight) \
                and an optional label.
                """
        )
    )
    var variant: [String] = []

    @Option(name: [.short, .long], help: "Output directory for snapshots")
    var outputDir: String = "."

    @Option(name: .long, help: "Image format")
    var format: ImageFormat = .jpeg

    @Option(name: .long, help: "JPEG quality 0.0–1.0 (ignored for PNG; default from config or 0.85)")
    var quality: Double?

    @Option(name: .long, help: "Which preview to capture (0-based index, ephemeral only)")
    var preview: Int = 0

    @Option(name: .long, help: "Window width (ephemeral session only)")
    var width: Int = 400

    @Option(name: .long, help: "Window height (ephemeral session only)")
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
        name: .long,
        help: "Target a specific running session by UUID instead of resolving by file"
    )
    var session: String?

    @Option(name: .long, help: "Path to .previewsmcp.json config file (auto-discovered if omitted)")
    var config: String?

    enum ImageFormat: String, ExpressibleByArgument, CaseIterable {
        case jpeg, png
    }

    mutating func run() async throws {
        guard !variant.isEmpty else {
            throw ValidationError("At least one --variant is required")
        }
        // Guard the JPEG-quality footgun: the daemon treats quality >=
        // 1.0 as "emit PNG", which would silently write PNG bytes into
        // a .jpg file. Reject upfront so the user can either drop
        // --quality or switch to --format png.
        if format == .jpeg, let quality, quality >= 1.0 {
            throw ValidationError(
                "--quality must be < 1.0 when --format jpeg; use --format png for lossless output."
            )
        }
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

        // Parse and dedupe-label-check variants locally so validation
        // errors fail before we pay the daemon roundtrip.
        let resolvedVariants: [PreviewTraits.Variant]
        do {
            resolvedVariants = try variant.map(PreviewTraits.parseVariantString)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
        var seen: [String: Int] = [:]
        for (index, v) in resolvedVariants.enumerated() {
            if let prior = seen[v.label] {
                throw ValidationError(
                    "Duplicate variant label '\(v.label)' at indices \(prior) and \(index). "
                        + "Provide a unique 'label' field in JSON variants.")
            }
            seen[v.label] = index
        }

        let outputDirURL = URL(fileURLWithPath: outputDir)
        try FileManager.default.createDirectory(
            at: outputDirURL, withIntermediateDirectories: true)

        let client = try await DaemonClient.connect(clientName: "previewsmcp-variants") { client in
            await client.onNotification(LogMessageNotification.self) { message in
                if case .string(let text) = message.params.data {
                    fputs("\(text)\n", stderr)
                }
            }
        }

        let exitCode: Int32
        do {
            let resolution = try await SessionResolver.resolve(
                session: session,
                file: file,
                client: client
            )

            switch resolution {
            case .found(let sessionID):
                exitCode = try await captureVariants(
                    sessionID: sessionID,
                    labels: resolvedVariants.map(\.label),
                    outputDir: outputDirURL,
                    client: client
                )
            case .notFound:
                guard let file else {
                    throw ValidationError(
                        "Session \(session ?? "?") not found. "
                            + "Pass a file path to create a new ephemeral session."
                    )
                }
                exitCode = try await captureEphemeral(
                    file: file,
                    labels: resolvedVariants.map(\.label),
                    outputDir: outputDirURL,
                    client: client
                )
            }
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }

        if exitCode != 0 { throw ExitCode(exitCode) }
    }

    // MARK: - Execution paths

    private func captureEphemeral(
        file: String,
        labels: [String],
        outputDir: URL,
        client: Client
    ) async throws -> Int32 {
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        let configResult = loadProjectConfig(explicit: config, fileURL: fileURL)
        let resolvedPlatform = SnapshotCommand.resolvePlatform(
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
            // Capture only — never show a window during variant rendering.
            "headless": .bool(true),
            "platform": .string(resolvedPlatform.rawValue),
        ]
        if let project { startArgs["projectPath"] = .string(project) }
        if let scheme { startArgs["scheme"] = .string(scheme) }
        if let device { startArgs["deviceUDID"] = .string(device) }
        if let config { startArgs["config"] = .string(config) }

        let startResponse = try await client.callTool(name: "preview_start", arguments: startArgs)
        if startResponse.isError == true {
            throw DaemonToolError.daemonError(
                "Failed to start preview: \(startResponse.content.joinedText())"
            )
        }
        let sessionID = try extractSessionID(from: startResponse.content.joinedText())

        do {
            let code = try await captureVariants(
                sessionID: sessionID,
                labels: labels,
                outputDir: outputDir,
                client: client
            )
            await stopEphemeralSession(sessionID: sessionID, client: client)
            return code
        } catch {
            await stopEphemeralSession(sessionID: sessionID, client: client)
            throw error
        }
    }

    /// Call `preview_variants`, decode each image block, write to disk,
    /// and surface any per-variant error text to stderr.
    private func captureVariants(
        sessionID: String,
        labels: [String],
        outputDir: URL,
        client: Client
    ) async throws -> Int32 {
        let requestedQuality = resolvedQuality()

        let arguments: [String: Value] = [
            "sessionID": .string(sessionID),
            "variants": .array(variant.map { .string($0) }),
            "quality": .double(requestedQuality),
        ]
        let response = try await client.callTool(name: "preview_variants", arguments: arguments)

        // Walk content items in order. The daemon emits, per variant,
        // either `[N] <label>:` followed by an image block (success) or
        // a single `[N] <label>: ERROR — <reason>` text block (failure).
        var successCount = 0
        var failCount = 0
        var pendingLabel: String?
        let ext = format == .png ? "png" : "jpg"

        for item in response.content {
            switch item {
            case .text(let text):
                // Prefer the failure pattern first — it's a strict
                // superset of the success preamble. A label that happens
                // to contain the substring "ERROR" (e.g. a JSON variant
                // labeled "ERROR_STATE") must still bucket as success
                // unless ` ERROR — ` follows the colon.
                if parseFailurePreamble(from: text) != nil {
                    fputs("\(text)\n", stderr)
                    failCount += 1
                    pendingLabel = nil
                } else if let label = parseSuccessPreamble(from: text) {
                    pendingLabel = label
                }
            case .image(let base64, _, _):
                guard let label = pendingLabel else {
                    fputs(
                        "warning: daemon returned image block with no preceding label preamble — dropping\n",
                        stderr
                    )
                    continue
                }
                guard let data = Data(base64Encoded: base64) else {
                    fputs("[error] \(label): invalid base64 from daemon\n", stderr)
                    failCount += 1
                    pendingLabel = nil
                    continue
                }
                let outURL = outputDir.appendingPathComponent("\(label).\(ext)")
                do {
                    try data.write(to: outURL)
                    print(outURL.path)
                    successCount += 1
                } catch {
                    fputs("[error] \(label): \(error.localizedDescription)\n", stderr)
                    failCount += 1
                }
                pendingLabel = nil
            default:
                continue
            }
        }

        // Labels expected but never matched imply the daemon dropped a
        // variant entirely — count them as failures so the exit code
        // reflects reality.
        let accounted = successCount + failCount
        if accounted < labels.count {
            let missing = labels.count - accounted
            fputs(
                "warning: daemon returned \(accounted) results for \(labels.count) variants\n",
                stderr
            )
            failCount += missing
        }
        return summarize(successCount: successCount, failCount: failCount)
    }

    // MARK: - Helpers

    private func resolvedQuality() -> Double {
        // Explicit --format png overrides quality → ask daemon for PNG
        // (quality >= 1.0 is its PNG trigger).
        if format == .png { return 1.0 }
        if let quality { return quality }
        return 0.85
    }

    private func summarize(successCount: Int, failCount: Int) -> Int32 {
        let total = successCount + failCount
        if failCount == 0 {
            fputs("Captured \(successCount)/\(total) variants.\n", stderr)
            return 0
        }
        fputs(
            "Captured \(successCount)/\(total) variants (\(failCount) failed). "
                + "See stderr for details.\n", stderr)
        return failCount == total ? 2 : 1
    }

    /// Match the daemon's success preamble: exactly `[N] <label>:` with
    /// no trailing content. Labels are sanitized upstream (no path
    /// traversal, no leading dots) so we don't need to validate them
    /// here beyond the structural match.
    private func parseSuccessPreamble(from text: String) -> String? {
        let pattern = /^\[\d+\]\s+(.+?):\s*$/
        guard let match = text.firstMatch(of: pattern) else { return nil }
        return String(match.1)
    }

    /// Match the daemon's failure text: `[N] <label>: ERROR — <reason>`.
    /// Anchored to the literal separator so a variant whose *label*
    /// contains "ERROR" is not mis-bucketed as a failure.
    private func parseFailurePreamble(from text: String) -> String? {
        let pattern = /^\[\d+\]\s+(.+?):\s+ERROR\s+—\s/
        guard let match = text.firstMatch(of: pattern) else { return nil }
        return String(match.1)
    }

    private func extractSessionID(from text: String) throws -> String {
        let pattern = /Session ID: ([0-9a-fA-F-]{36})/
        guard let match = text.firstMatch(of: pattern) else {
            throw DaemonToolError.daemonError(
                "no session ID in daemon response: \(text)"
            )
        }
        return String(match.1)
    }

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
}

